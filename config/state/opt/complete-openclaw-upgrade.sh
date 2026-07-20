#!/bin/bash
# complete-openclaw-upgrade.sh
# Full OpenClaw upgrade automation.
# Assumes release notes have been reviewed externally beforehand.
# Leaves harvest/commit as a separate manual step.

set -euo pipefail

OPENCLAW_ENV_FILE="/opt/openclaw.env"
GATEWAY_ENV_FILE="/etc/openclaw-gateway.env"

extract_semver() {
    printf '%s\n' "$1" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1
}

load_openclaw_environment() {
    local env_file

    for env_file in "$OPENCLAW_ENV_FILE" "$GATEWAY_ENV_FILE"; do
        if [[ ! -r "$env_file" ]]; then
            echo "Required environment file is not readable: $env_file" >&2
            exit 1
        fi

        set -a
        # These are root-managed systemd EnvironmentFile inputs.
        source "$env_file"
        set +a
    done

    if [[ "${OPENCLAW_SERVICE_REPAIR_POLICY:-}" != "external" ]]; then
        echo "OPENCLAW_SERVICE_REPAIR_POLICY must be external before running Doctor." >&2
        exit 1
    fi
    if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
        echo "OPENCLAW_GATEWAY_TOKEN is missing from $GATEWAY_ENV_FILE." >&2
        exit 1
    fi

    export OPENCLAW_REMOTE_TOKEN="${OPENCLAW_REMOTE_TOKEN:-$OPENCLAW_GATEWAY_TOKEN}"
}

run_openclaw() {
    sudo -u openclaw -H \
        --preserve-env=OPENCLAW_GATEWAY_TOKEN,OPENCLAW_REMOTE_TOKEN,OPENCLAW_SERVICE_KIND,OPENCLAW_SERVICE_REPAIR_POLICY \
        openclaw "$@"
}

load_openclaw_environment

echo "=== OpenClaw Complete Upgrade ==="
echo ""

# Check current version
CURRENT_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
echo "Current version: $CURRENT_VERSION"
CURRENT_SEMVER=$(extract_semver "$CURRENT_VERSION" || true)

# Accept an optional guarded resume mode, then the target version.
RESUME_AFTER_INSTALL=false
if [[ "${1:-}" == "--resume-after-install" ]]; then
    RESUME_AFTER_INSTALL=true
    shift
fi

TARGET_VERSION="${1:-}"
if [[ -z "$TARGET_VERSION" ]]; then
    read -p "Enter target version (e.g., 2026.5.21 or 'latest'): " TARGET_VERSION
fi
if [[ -z "$TARGET_VERSION" ]]; then
    echo "No version specified. Aborting."
    exit 1
fi
if [[ ! "$TARGET_VERSION" =~ ^([0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?|latest)$ ]]; then
    echo "Target must be an exact OpenClaw version or 'latest'. Aborting." >&2
    exit 1
fi
if [[ "$RESUME_AFTER_INSTALL" == true && "$TARGET_VERSION" == "latest" ]]; then
    echo "Resume mode requires an exact package version. Aborting." >&2
    exit 1
fi

# Confirm
echo ""
echo "⚠️  This will:"
if [[ "$RESUME_AFTER_INSTALL" == true ]]; then
    echo "  - Resume after verifying openclaw@${TARGET_VERSION} is installed and the gateway is stopped"
else
    echo "  1. Create a verified OpenClaw backup"
    echo "  2. Stop the gateway"
    echo "  3. Install openclaw@${TARGET_VERSION}"
    echo "  4. Verify axios integrity"
fi
echo "  5. Preview and confirm offline Doctor repairs"
echo "  6. Reconcile tracked plugins (may prompt for approval)"
echo "  7. Update /opt/openclaw.env"
echo "  8. Start the gateway"
echo "  9. Verify the version and plugin compatibility"
echo " 10. Verify workspace file protection"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

if [[ "$RESUME_AFTER_INSTALL" == true ]]; then
    SYSTEM_PACKAGE_VERSION=$(node -p "require('/usr/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)
    if [[ "$SYSTEM_PACKAGE_VERSION" != "$TARGET_VERSION" ]]; then
        echo "Installed system package is ${SYSTEM_PACKAGE_VERSION:-unknown}, expected $TARGET_VERSION. Aborting." >&2
        exit 1
    fi
    if systemctl is-active --quiet openclaw; then
        echo "Gateway must be stopped before resuming offline repairs. Aborting." >&2
        exit 1
    fi
    echo "Resuming with verified openclaw@${SYSTEM_PACKAGE_VERSION}; gateway is stopped."
else
    # Step 1: Create a verified backup before any package or state migration.
    echo ""
    echo "--- Step 1: Creating verified backup ---"
    BACKUP_DIR="/home/openclaw/Backups/openclaw"
    install -d -m 700 -o openclaw -g openclaw "$BACKUP_DIR"
    run_openclaw backup create --output "$BACKUP_DIR" --verify

    # Step 2: Stop the externally supervised gateway before replacing package
    # files or migrating persistent state.
    echo ""
    echo "--- Step 2: Stopping gateway ---"
    systemctl stop openclaw

    # Step 3: Install update
    echo ""
    echo "--- Step 3: Installing openclaw@${TARGET_VERSION} ---"
    sudo npm install -g "openclaw@${TARGET_VERSION}"

    # Step 4: Verify axios integrity
    echo ""
    echo "--- Step 4: Verifying axios integrity ---"
    AXIOS_FOUND=$(find /usr/lib/node_modules/openclaw -name "package.json" -path "*/axios/package.json" 2>/dev/null | xargs grep '"version"' 2>/dev/null || echo "")
    if [[ -z "$AXIOS_FOUND" ]]; then
        echo "⚠️  No bundled axios package found at the historical path under /usr/lib/node_modules/openclaw."
        echo "    This can happen when the package layout changes. Treat release notes/security advisories as the primary source of truth for the target version."
    else
        echo "Axios version: $AXIOS_FOUND"
        if echo "$AXIOS_FOUND" | grep -qE "1\.14\.1|0\.30\.4"; then
            echo "❌ COMPROMISED AXIOS VERSION DETECTED. Rolling back."
            if [[ -n "$CURRENT_SEMVER" ]]; then
                sudo npm install -g "openclaw@${CURRENT_SEMVER}"
            else
                echo "❌ Could not identify the previous package version for rollback."
            fi
            echo "Gateway remains stopped. Inspect the package before starting it."
            exit 1
        fi
    fi
fi

# Step 5: Preview and explicitly approve offline state/config migrations.
echo ""
echo "--- Step 5: Previewing Doctor repairs ---"
DOCTOR_OUTPUT=$(run_openclaw doctor --non-interactive 2>&1 || true)
echo "$DOCTOR_OUTPUT"

if echo "$DOCTOR_OUTPUT" | grep -q "doctor --fix"; then
    echo ""
    read -p "Apply the Doctor repairs shown above while the gateway is stopped? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted before state migration. The gateway remains stopped for review."
        exit 1
    fi

    run_openclaw doctor --fix --non-interactive --yes

    if [[ -f /home/openclaw/.openclaw/npm/package.json ]]; then
        echo ""
        echo "npm/package.json detected. Running npm install --no-bin-links..."
        sudo -u openclaw -H bash -c 'cd /home/openclaw/.openclaw/npm && npm install --no-bin-links'
        echo "npm reinstall complete."
    fi
fi

# Step 6: Reconcile plugins
echo ""
echo "--- Step 6: Reconciling plugins ---"
PLUGINS_JSON=$(run_openclaw plugins inspect --all --json 2>/dev/null || echo "{}")
echo "Current plugins:"
echo "$PLUGINS_JSON" | jq -r '.[] | if .plugin then "\(.plugin.id): \(.plugin.version) (\(.plugin.rootDir))" else "\(.id): \(.version) (\(.rootDir))" end' 2>/dev/null || echo "(Could not parse plugins)"

echo ""
echo "Checking for available plugin updates..."
DRY_RUN=$(run_openclaw plugins update --all --dry-run 2>/dev/null || echo "")
if [[ -z "${DRY_RUN//[[:space:]]/}" ]]; then
    echo "No plugin updates available."
elif echo "$DRY_RUN" | grep -qiE 'is up to date' && ! echo "$DRY_RUN" | grep -qiE 'update available|would update|will update|->'; then
    echo "No plugin updates available."
    echo "$DRY_RUN"
elif [[ -n "$DRY_RUN" ]]; then
    echo "Available updates:"
    echo "$DRY_RUN"
    read -p "Apply plugin updates? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing plugin updates..."
        run_openclaw plugins update --all
    else
        echo "Skipping plugin updates."
    fi
else
    echo "No plugin updates available."
fi

echo ""
echo "Verifying Codex (critical runtime plugin)..."
CODEX_INFO=$(run_openclaw plugins inspect codex --json 2>/dev/null || echo "{}")
echo "$CODEX_INFO" | jq '.' 2>/dev/null || echo "$CODEX_INFO"

# Step 7: Update /opt/openclaw.env
echo ""
echo "--- Step 7: Updating /opt/openclaw.env ---"
NEW_CLI_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
NEW_CLI_SEMVER=$(extract_semver "$NEW_CLI_VERSION" || true)
if [[ -z "$NEW_CLI_SEMVER" ]]; then
    echo "❌ Could not extract semantic version from: $NEW_CLI_VERSION"
    exit 1
fi
echo "New CLI version: $NEW_CLI_VERSION"
sudo sed -i "s/OPENCLAW_VERSION=.*/OPENCLAW_VERSION=${NEW_CLI_SEMVER}/" /opt/openclaw.env
echo "Updated /opt/openclaw.env:"
grep OPENCLAW_VERSION /opt/openclaw.env

# Step 8: Start gateway
echo ""
echo "--- Step 8: Starting gateway ---"
systemctl start openclaw

# Step 9: Verify versions
echo ""
echo "--- Step 9: Verifying new version and plugins ---"
CLI_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
GATEWAY_STATUS=""
for attempt in {1..30}; do
    GATEWAY_STATUS=$(run_openclaw gateway status --deep 2>&1 || true)
    if echo "$GATEWAY_STATUS" | grep -q "Connectivity probe: ok"; then
        break
    fi
    if [[ $attempt -lt 30 ]]; then
        sleep 2
    fi
done
echo "CLI version: $CLI_VERSION"
echo "Gateway status: $GATEWAY_STATUS"

if echo "$GATEWAY_STATUS" | grep -q "version mismatch"; then
    echo "❌ VERSION MISMATCH DETECTED. Check /opt/openclaw.env and systemctl restart."
    exit 1
fi
if ! echo "$GATEWAY_STATUS" | grep -q "Connectivity probe: ok"; then
    echo "❌ GATEWAY CONNECTIVITY FAILED AFTER 60 SECONDS."
    echo "The service remains running for inspection."
    exit 1
fi

run_openclaw doctor --post-upgrade

# Step 10: Verify workspace file protection
echo ""
echo "--- Step 10: Verifying workspace file protection ---"
if [[ -x /opt/protect-workspace.sh ]]; then
    if /opt/protect-workspace.sh check; then
        echo "Workspace file protection verified."
    else
        echo "❌ WORKSPACE FILE PROTECTION CHECK FAILED."
        echo "Review /home/openclaw/.openclaw/workspace/working/sls-system/immutable-check.json and restore protection before treating the upgrade as complete."
        exit 1
    fi
else
    echo "⚠️  /opt/protect-workspace.sh not found. Skipping workspace protection check."
fi

echo ""
echo "✅ Upgrade complete!"
echo ""
echo "--- Control UI Note ---"
echo "If the browser shows 'Auth required' after this upgrade, the gateway is usually reachable but your tab does not have a fresh credential."
echo "In headless SSH sessions, 'openclaw dashboard --no-open' may print only the base URL when it cannot open a browser or copy the tokenized URL to a clipboard."
echo "Host-side recovery:"
echo "  sudo -u openclaw openclaw dashboard --no-open"
echo "If that command says 'Token auto-auth not delivered', open your Control UI URL and append '#token=<gateway token>' manually using your existing host-side token source. Do not paste the token into chat."
echo ""
echo "--- Next Step: Manual Harvest and Commit ---"
echo "When ready, run:"
echo ""
echo "  sudo bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh"
echo "  git -C /home/openclaw/.openclaw/projects/sls-config add config/"
echo "  git -C /home/openclaw/.openclaw/projects/sls-config commit -m \"harvest after openclaw update to ${NEW_CLI_SEMVER}\""
echo "  git -C /home/openclaw/.openclaw/projects/sls-config push"
echo ""
