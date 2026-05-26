#!/bin/bash
# complete-openclaw-upgrade.sh
# Full OpenClaw upgrade automation (steps 3-10 of MAINTENANCE.md)
# Assumes release notes have been reviewed externally beforehand.
# Leaves harvest/commit as a separate manual step.

set -e

echo "=== OpenClaw Complete Upgrade ==="
echo ""

# Check current version
CURRENT_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
echo "Current version: $CURRENT_VERSION"

# Prompt for target version
read -p "Enter target version (e.g., 2026.5.21 or 'latest'): " TARGET_VERSION
if [[ -z "$TARGET_VERSION" ]]; then
    echo "No version specified. Aborting."
    exit 1
fi

# Confirm
echo ""
echo "⚠️  This will:"
echo "  1. Back up OpenClaw config"
echo "  2. Install openclaw@${TARGET_VERSION}"
echo "  3. Verify axios integrity"
echo "  4. Run doctor and doctor --fix"
echo "  5. Reconcile tracked plugins (may prompt for approval)"
echo "  6. Update /opt/openclaw.env"
echo "  7. Restart the gateway"
echo "  8. Verify new version"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Step 2: Backup config
echo ""
echo "--- Step 1: Backing up config ---"
sudo -u openclaw -s -- sh -c 'cd ~ && openclaw backup create --only-config'

# Step 3: Install update
echo ""
echo "--- Step 2: Installing openclaw@${TARGET_VERSION} ---"
sudo npm install -g "openclaw@${TARGET_VERSION}"

# Step 4: Verify axios integrity
echo ""
echo "--- Step 3: Verifying axios integrity ---"
AXIOS_FOUND=$(find /usr/lib/node_modules/openclaw -name "package.json" -path "*/axios/package.json" 2>/dev/null | xargs grep '"version"' 2>/dev/null || echo "")
if [[ -z "$AXIOS_FOUND" ]]; then
    echo "⚠️  Could not verify axios version. Proceeding cautiously."
else
    echo "Axios version: $AXIOS_FOUND"
    if echo "$AXIOS_FOUND" | grep -qE "1\.14\.1|0\.30\.4"; then
        echo "❌ COMPROMISED AXIOS VERSION DETECTED. Rolling back."
        sudo npm install -g "openclaw@${CURRENT_VERSION}"
        exit 1
    fi
fi

# Step 5: Run doctor
echo ""
echo "--- Step 4: Running openclaw doctor ---"
DOCTOR_OUTPUT=$(sudo -u openclaw openclaw doctor 2>&1 || true)
echo "$DOCTOR_OUTPUT"

if echo "$DOCTOR_OUTPUT" | grep -q "doctor --fix"; then
    echo ""
    echo "Doctor suggests fixes. Running doctor --fix..."
    sudo -u openclaw openclaw doctor --fix
    
    if [[ -f /home/openclaw/.openclaw/npm/package.json ]]; then
        echo ""
        echo "npm/package.json detected. Running npm install --no-bin-links..."
        cd /home/openclaw/.openclaw/npm
        npm install --no-bin-links
        echo "npm reinstall complete."
    fi
fi

# Step 6: Reconcile plugins
echo ""
echo "--- Step 5: Reconciling plugins ---"
PLUGINS_JSON=$(sudo -u openclaw openclaw plugins inspect --all --json 2>/dev/null || echo "{}")
echo "Current plugins:"
echo "$PLUGINS_JSON" | jq -r '.[] | "\(.id): \(.version) (\(.rootDir))"' 2>/dev/null || echo "(Could not parse plugins)"

echo ""
echo "Checking for available plugin updates..."
DRY_RUN=$(sudo -u openclaw openclaw plugins update --all --dry-run 2>/dev/null || echo "")
if [[ -n "$DRY_RUN" ]]; then
    echo "Available updates:"
    echo "$DRY_RUN"
    read -p "Apply plugin updates? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing plugin updates..."
        sudo -u openclaw openclaw plugins update --all
    else
        echo "Skipping plugin updates."
    fi
else
    echo "No plugin updates available."
fi

echo ""
echo "Verifying Codex (critical runtime plugin)..."
CODEX_INFO=$(sudo -u openclaw openclaw plugins inspect codex --json 2>/dev/null || echo "{}")
echo "$CODEX_INFO" | jq '.' 2>/dev/null || echo "$CODEX_INFO"

# Step 7: Update /opt/openclaw.env
echo ""
echo "--- Step 6: Updating /opt/openclaw.env ---"
NEW_CLI_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
echo "New CLI version: $NEW_CLI_VERSION"
sudo sed -i "s/OPENCLAW_VERSION=.*/OPENCLAW_VERSION=${NEW_CLI_VERSION}/" /opt/openclaw.env
echo "Updated /opt/openclaw.env:"
grep OPENCLAW_VERSION /opt/openclaw.env

# Step 8: Restart gateway
echo ""
echo "--- Step 7: Restarting gateway ---"
sudo systemctl restart openclaw
sleep 2

# Step 9: Verify versions
echo ""
echo "--- Step 8: Verifying new version ---"
CLI_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
GATEWAY_STATUS=$(openclaw gateway status 2>/dev/null || echo "Gateway status unavailable")
echo "CLI version: $CLI_VERSION"
echo "Gateway status: $GATEWAY_STATUS"

if echo "$GATEWAY_STATUS" | grep -q "version mismatch"; then
    echo "❌ VERSION MISMATCH DETECTED. Check /opt/openclaw.env and systemctl restart."
    exit 1
fi

echo ""
echo "✅ Upgrade complete!"
echo ""
echo "--- Next Step: Manual Harvest and Commit ---"
echo "When ready, run:"
echo ""
echo "  sudo bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh"
echo "  git -C /home/openclaw/.openclaw/projects/sls-config add config/"
echo "  git -C /home/openclaw/.openclaw/projects/sls-config commit -m \"harvest after openclaw update to ${NEW_CLI_VERSION}\""
echo "  git -C /home/openclaw/.openclaw/projects/sls-config push"
echo ""
