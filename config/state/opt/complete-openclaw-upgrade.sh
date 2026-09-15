#!/bin/bash
# complete-openclaw-upgrade.sh
# Full OpenClaw upgrade automation.
# Assumes release notes have been reviewed externally beforehand.
# Leaves harvest/commit as a separate manual step.

set -Eeuo pipefail

cd -- /home/openclaw

OPENCLAW_ENV_FILE="/opt/openclaw.env"
GATEWAY_ENV_FILE="/etc/openclaw-gateway.env"

extract_semver() {
    printf '%s\n' "$1" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -1
}

validate_stage_combination() {
    local mode="$1"
    local target_version="$2"
    local node_version="$3"
    local current_version="$4"
    local expected_current_version

    case "$target_version:$node_version" in
        2026.9.2:v22.23.2)
            expected_current_version="2026.7.1-2"
            ;;
        2026.9.4:v26.*)
            expected_current_version="2026.9.2"
            ;;
        *)
            echo "Unsupported staged target/runtime combination: openclaw@${target_version} on ${node_version:-unknown}." >&2
            return 1
            ;;
    esac

    case "$mode" in
        --prepare | --execute)
            ;;
        --resume-after-install)
            expected_current_version="$target_version"
            ;;
        *)
            echo "Unsupported staged-upgrade mode: $mode." >&2
            return 1
            ;;
    esac

    if [[ "$current_version" != "$expected_current_version" ]]; then
        echo "Stage requires openclaw@${expected_current_version}; found ${current_version:-unknown}." >&2
        return 1
    fi
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
    env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
    openclaw "$@"
}

verify_external_service_contract() {
    if ! cmp -s /opt/openclaw-cli.sh /home/openclaw/.openclaw/projects/sls-config/config/state/opt/openclaw-cli.sh; then
        echo "Operator wrapper differs from its reviewed tracked snapshot. Aborting." >&2
        exit 1
    fi
    if ! cmp -s /etc/systemd/system/openclaw.service /home/openclaw/.openclaw/projects/sls-config/config/state/systemd/openclaw.service; then
        echo "OpenClaw service unit differs from its reviewed tracked snapshot. Aborting." >&2
        exit 1
    fi
    if [[ "$(systemctl show openclaw -p User --value)" != "openclaw" ]]; then
        echo "OpenClaw service must run as user openclaw. Aborting." >&2
        exit 1
    fi
    if [[ "$(systemctl show openclaw -p Group --value)" != "openclaw" ]]; then
        echo "OpenClaw service must run as group openclaw. Aborting." >&2
        exit 1
    fi
    if ! systemctl show openclaw -p ExecStart --value | grep -Fq '/usr/bin/openclaw gateway'; then
        echo "OpenClaw service executable contract has drifted. Aborting." >&2
        exit 1
    fi
}

verify_backup_proof() {
    local backup_archive="$1"
    local expected_sha256="$2"
    local resume_after_install="$3"
    local predecessor_version="$4"

    sudo -u openclaw -H \
        --preserve-env=OPENCLAW_GATEWAY_TOKEN,OPENCLAW_REMOTE_TOKEN,OPENCLAW_SERVICE_KIND,OPENCLAW_SERVICE_REPAIR_POLICY \
        python3 - "$BACKUP_DIR" "$backup_archive" "$expected_sha256" "$resume_after_install" "$predecessor_version" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

backup_dir = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
expected_sha256 = sys.argv[3]
resume_after_install = sys.argv[4] == "true"
predecessor_version = sys.argv[5]

if not archive_path.is_absolute() or archive_path.parent != backup_dir:
    raise SystemExit(f"Backup archive must be directly inside {backup_dir}")

directory_fd = os.open(backup_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    archive_fd = os.open(
        archive_path.name,
        os.O_RDONLY | os.O_NOFOLLOW,
        dir_fd=directory_fd,
    )
finally:
    os.close(directory_fd)

try:
    if not stat.S_ISREG(os.fstat(archive_fd).st_mode):
        raise SystemExit("Backup archive is not a regular file")

    digest = hashlib.file_digest(os.fdopen(os.dup(archive_fd), "rb"), "sha256")
    if digest.hexdigest() != expected_sha256:
        raise SystemExit("Local and off-host backup checksums do not match")

    os.lseek(archive_fd, 0, os.SEEK_SET)
    verifier_path = f"/proc/{os.getpid()}/fd/{archive_fd}"
    verifier_env = os.environ.copy()
    for key in ("SUDO_USER", "SUDO_UID", "SUDO_GID", "SUDO_COMMAND"):
        verifier_env.pop(key, None)
    current_verification = subprocess.run(
        ["/usr/bin/openclaw", "backup", "verify", verifier_path],
        check=False,
        capture_output=True,
        env=verifier_env,
        text=True,
    )
    if current_verification.returncode == 0:
        print(current_verification.stdout, end="")
    else:
        verification_detail = (
            current_verification.stdout + current_verification.stderr
        )
        compatibility_error = "Archive symbolic link target must be relative:"
        if not resume_after_install or compatibility_error not in verification_detail:
            print(verification_detail, end="", file=sys.stderr)
            current_verification.check_returncode()

        print(
            f"Installed verifier rejected legacy links; retrying with exact "
            f"openclaw@{predecessor_version} in temporary storage."
        )
        with tempfile.TemporaryDirectory(prefix="openclaw-backup-verifier-") as temporary_root:
            subprocess.run(
                [
                    "/usr/bin/npm",
                    "install",
                    "--prefix",
                    temporary_root,
                    "--ignore-scripts",
                    "--no-audit",
                    "--no-fund",
                    f"openclaw@{predecessor_version}",
                ],
                check=True,
                env=verifier_env,
                stdout=subprocess.DEVNULL,
            )
            package_file = Path(temporary_root) / "node_modules/openclaw/package.json"
            legacy_package_version = json.loads(package_file.read_text())["version"]
            if legacy_package_version != predecessor_version:
                raise SystemExit("Temporary verifier package version mismatch")
            legacy_verifier = Path(temporary_root) / "node_modules/.bin/openclaw"
            subprocess.run(
                [legacy_verifier, "backup", "verify", verifier_path],
                check=True,
                env=verifier_env,
            )
finally:
    os.close(archive_fd)
PY
}

load_openclaw_environment
verify_external_service_contract

echo "=== OpenClaw Complete Upgrade ==="
echo ""

# Check current version
CURRENT_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
echo "Current version: $CURRENT_VERSION"
CURRENT_SEMVER=$(extract_semver "$CURRENT_VERSION" || true)

# Require an explicit stage boundary. Preparation never stops the Gateway;
# execution requires proof that the prepared archive was copied off-host.
MODE="${1:-}"
case "$MODE" in
    --prepare | --execute | --resume-after-install)
        shift
        ;;
    *)
        echo "Usage: $0 --prepare <target-version>" >&2
        echo "       $0 --execute <target-version> <archive> <off-host-sha256>" >&2
        echo "       $0 --resume-after-install <target-version> <archive> <off-host-sha256>" >&2
        exit 1
        ;;
esac

TARGET_VERSION="${1:-}"
shift || true
BACKUP_ARCHIVE=""
OFF_HOST_SHA256=""
if [[ "$MODE" != "--prepare" ]]; then
    BACKUP_ARCHIVE="${1:-}"
    OFF_HOST_SHA256="${2:-}"
    shift 2 || true
fi
if [[ -z "$TARGET_VERSION" || $# -ne 0 ]]; then
    echo "Invalid staged-upgrade arguments. Aborting." >&2
    exit 1
fi

NODE_VERSION=$(/usr/bin/node --version 2>/dev/null || true)
RESUME_AFTER_INSTALL=false
if [[ "$MODE" == "--resume-after-install" ]]; then
    RESUME_AFTER_INSTALL=true
fi
if ! validate_stage_combination "$MODE" "$TARGET_VERSION" "$NODE_VERSION" "$CURRENT_SEMVER"; then
    echo "Staged upgrade preflight failed. Aborting." >&2
    exit 1
fi

case "$TARGET_VERSION" in
    2026.9.2)
        EXPECTED_PREDECESSOR_VERSION="2026.7.1-2"
        ;;
    2026.9.4)
        EXPECTED_PREDECESSOR_VERSION="2026.9.2"
        ;;
esac

BACKUP_DIR="/home/openclaw/Backups/openclaw"
if [[ "$MODE" != "--prepare" ]]; then
    if [[ ! "$OFF_HOST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo "A lowercase SHA-256 observed on the off-host copy is required. Aborting." >&2
        exit 1
    fi
    verify_backup_proof \
        "$BACKUP_ARCHIVE" \
        "$OFF_HOST_SHA256" \
        "$RESUME_AFTER_INSTALL" \
        "$EXPECTED_PREDECESSOR_VERSION"
fi

# Confirm
echo ""
echo "⚠️  This will:"
if [[ "$MODE" == "--prepare" ]]; then
    echo "  - Create and vendor-verify a named full backup"
    echo "  - Print its SHA-256 and stop before package or service mutation"
elif [[ "$RESUME_AFTER_INSTALL" == true ]]; then
    echo "  - Resume after verifying openclaw@${TARGET_VERSION} is installed and the gateway is stopped"
else
    echo "  1. Re-verify the selected backup and matching off-host checksum"
    echo "  2. Stop the gateway"
    echo "  3. Install openclaw@${TARGET_VERSION}"
    echo "  4. Verify axios integrity"
fi
echo "  5. Preview and confirm offline Doctor repairs"
echo "  6. Reconcile tracked plugins (may prompt for approval)"
echo "  7. Preserve the approved security posture and validate config"
echo "  8. Update /opt/openclaw.env"
echo "  9. Start the gateway"
echo " 10. Verify the version and plugin compatibility"
echo " 11. Verify workspace file protection"
echo " 12. Replay the live morning pipeline"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

if [[ "$MODE" == "--prepare" ]]; then
    echo ""
    echo "--- Preparing verified recovery archive ---"
    install -d -m 700 -o openclaw -g openclaw "$BACKUP_DIR"
    BACKUP_ARCHIVE="$BACKUP_DIR/$(date -u +%Y-%m-%dT%H-%M-%SZ)-pre-openclaw-${TARGET_VERSION}.tar.gz"
    run_openclaw backup create --output "$BACKUP_ARCHIVE" --verify
    BACKUP_SHA256=$(sha256sum "$BACKUP_ARCHIVE" | awk '{print $1}')
    echo "Prepared archive: $BACKUP_ARCHIVE"
    echo "On-host SHA-256: $BACKUP_SHA256"
    echo "Copy this archive off-host and compute SHA-256 there. Do not execute the stage until it matches."
    echo "Then run:"
    echo "  sudo $0 --execute $TARGET_VERSION $BACKUP_ARCHIVE <off-host-sha256>"
    exit 0
elif [[ "$RESUME_AFTER_INSTALL" == true ]]; then
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
    # Step 2: Stop the externally supervised gateway before replacing package
    # files or migrating persistent state.
    echo ""
    echo "--- Step 2: Stopping gateway ---"
    systemctl stop openclaw

    # Step 3: Install update
    echo ""
    echo "--- Step 3: Installing openclaw@${TARGET_VERSION} ---"
    NODE_EXECUTABLE_BEFORE_INSTALL=$(readlink -f /usr/bin/node)
    NODE_VERSION_BEFORE_INSTALL=$(/usr/bin/node --version)
    sudo npm install -g "openclaw@${TARGET_VERSION}"
    NODE_EXECUTABLE_AFTER_INSTALL=$(readlink -f /usr/bin/node)
    NODE_VERSION_AFTER_INSTALL=$(/usr/bin/node --version)
    if [[ "$NODE_EXECUTABLE_AFTER_INSTALL" != "$NODE_EXECUTABLE_BEFORE_INSTALL" ||
        "$NODE_VERSION_AFTER_INSTALL" != "$NODE_VERSION_BEFORE_INSTALL" ]]; then
        echo "Node runtime changed during the core-only stage. Gateway remains stopped." >&2
        exit 1
    fi
    INSTALLED_PACKAGE_VERSION=$(node -p "require('/usr/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)
    if [[ "$INSTALLED_PACKAGE_VERSION" != "$TARGET_VERSION" ]]; then
        echo "Installed package ${INSTALLED_PACKAGE_VERSION:-unknown} does not match target $TARGET_VERSION. Gateway remains stopped." >&2
        exit 1
    fi
    INSTALLED_CLI_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
    INSTALLED_CLI_SEMVER=$(extract_semver "$INSTALLED_CLI_VERSION" || true)
    if [[ "$INSTALLED_CLI_SEMVER" != "$TARGET_VERSION" ]]; then
        echo "Installed CLI ${INSTALLED_CLI_SEMVER:-unknown} does not match target $TARGET_VERSION. Gateway remains stopped." >&2
        exit 1
    fi

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
echo "--- Step 6: Reconciling exact Codex generation ---"
CODEX_INFO=$(run_openclaw plugins inspect codex --json 2>/dev/null || echo "{}")
echo "$CODEX_INFO" | jq '.' 2>/dev/null || echo "$CODEX_INFO"

echo ""
read -p "Install exact @openclaw/codex@${TARGET_VERSION} with its reviewed capabilities? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Codex reconciliation was not approved. The Gateway remains stopped." >&2
    exit 1
fi

run_openclaw plugins install "@openclaw/codex@${TARGET_VERSION}" --force --pin
CODEX_INFO=$(run_openclaw plugins inspect codex --json)
CODEX_SPEC=$(echo "$CODEX_INFO" | jq -r '.install.spec // empty')
if [[ "$CODEX_SPEC" != "@openclaw/codex@${TARGET_VERSION}" ]]; then
    echo "Codex install.spec is not pinned to the exact target generation. Gateway remains stopped." >&2
    exit 1
fi

# Step 7: Preserve the explicitly approved pre-upgrade security posture before
# the upgraded Gateway can expose default-on Swarm or cross-agent access.
echo ""
echo "--- Step 7: Applying approved security posture ---"
SECURITY_POSTURE_BATCH='[
    {"path":"tools.swarm","value":false},
    {"path":"tools.sessions.visibility","value":"agent"},
    {"path":"tools.agentToAgent.enabled","value":false}
]'
run_openclaw config set --batch-json "$SECURITY_POSTURE_BATCH" --dry-run
run_openclaw config set --batch-json "$SECURITY_POSTURE_BATCH"
run_openclaw config validate

# Step 8: Update /opt/openclaw.env
echo ""
echo "--- Step 8: Updating /opt/openclaw.env ---"
NEW_CLI_VERSION=$(run_openclaw --version 2>/dev/null || echo "unknown")
NEW_CLI_SEMVER=$(extract_semver "$NEW_CLI_VERSION" || true)
if [[ "$NEW_CLI_SEMVER" != "$TARGET_VERSION" ]]; then
    echo "❌ CLI version ${NEW_CLI_SEMVER:-unknown} does not match target $TARGET_VERSION"
    exit 1
fi
echo "New CLI version: $NEW_CLI_VERSION"
sudo sed -i "s|OPENCLAW_VERSION=.*|OPENCLAW_VERSION=${NEW_CLI_SEMVER}|" /opt/openclaw.env
echo "Updated /opt/openclaw.env:"
grep OPENCLAW_VERSION /opt/openclaw.env

# Step 9: Start gateway
echo ""
echo "--- Step 9: Starting gateway ---"
stop_gateway_on_validation_error() {
    local status=$?
    if [[ $status -eq 0 ]]; then
        status=1
    fi
    echo "Acceptance failed during ${VALIDATION_PHASE}; stopping the Gateway." >&2
    systemctl stop openclaw || true
    exit "$status"
}
VALIDATION_PHASE="Gateway startup"
trap stop_gateway_on_validation_error ERR INT TERM
systemctl start openclaw

# Step 10: Verify versions
echo ""
echo "--- Step 10: Verifying new version and plugins ---"
VALIDATION_PHASE="Gateway connectivity"
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
    echo "The Gateway will be stopped; use the reviewed resume path after diagnosis."
    exit 1
fi

VALIDATION_PHASE="post-upgrade Doctor"
run_openclaw doctor --post-upgrade

# Step 11: Verify workspace file protection
echo ""
echo "--- Step 11: Verifying workspace file protection ---"
VALIDATION_PHASE="workspace protection"
if [[ -x /opt/protect-workspace.sh ]]; then
    if /opt/protect-workspace.sh check; then
        echo "Workspace file protection verified."
    else
        echo "❌ WORKSPACE FILE PROTECTION CHECK FAILED."
        echo "Review /home/openclaw/.openclaw/workspace/working/sls-system/immutable-check.json and restore protection before treating the upgrade as complete."
        stop_gateway_on_validation_error
    fi
else
    echo "⚠️  /opt/protect-workspace.sh not found. Skipping workspace protection check."
fi

# Step 12: Exercise the real scheduler and agent execution path. Static health
# checks cannot detect interactive plugin approvals or other cron-only failures.
echo ""
echo "--- Step 12: Replaying live morning pipeline ---"
VALIDATION_PHASE="live morning pipeline replay"
PIPELINE_REPLAY_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
/home/openclaw/.openclaw/cron/run-morning-pipeline.sh

echo ""
echo "✅ Live upgrade validation complete."
trap - ERR INT TERM
echo "Scheduled proof remains pending until the next normal weather, Oura, and calendar runs."
echo "Then verify those non-manual runs with:"
echo "  sudo /home/openclaw/.openclaw/cron/verify-scheduled-cron-success.sh --since-iso ${PIPELINE_REPLAY_STARTED_AT}"
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
