#!/usr/bin/env bash
# =============================================================================
# rotate-openclaw-gateway.sh — Gateway Token Rotation Script
# =============================================================================
#
# PURPOSE:
#   Rotates the OpenClaw gateway authentication token.
#
#   Current sls policy:
#     1. ~/.openclaw/openclaw.json      — canonical runtime config
#        (gateway.auth.token and gateway.remote.token)
#     2. /opt/openclaw.env              — must NOT contain
#        OPENCLAW_GATEWAY_TOKEN; should contain
#        OPENCLAW_SERVICE_KIND=gateway
#     3. ~/.openclaw/gateway-token.txt  — optional legacy convenience file;
#        keep in sync only if you still intentionally use it
#
#   This changed after the 2026-05-13 Telegram outage, where a stale
#   OPENCLAW_GATEWAY_TOKEN in /opt/openclaw.env drifted from config and caused
#   internal gateway client token_mismatch failures.
#
# USAGE:
#   Run as root:
#   sudo bash /opt/rotate-openclaw-gateway.sh
#
# NOTE ON openclaw.json:
#   The ONLY openclaw.json that matters is /home/openclaw/.openclaw/openclaw.json.
#   /root/.openclaw/ should NOT exist. If it does, root ran an openclaw config
#   command and recreated it — investigate, correct under the openclaw user, and
#   delete it: sudo rm -rf /root/.openclaw/
#
# AFTER ROTATION:
#   - Existing paired devices maintain their sessions (verified Apr 3, 2026)
#   - The new token is only required for NEW pairings
#   - Verify with: openclaw devices list
#
# See extras/MAINTENANCE.md for the full rotation procedure and context.
# =============================================================================

set -euo pipefail

# Generate a new cryptographically random token
if command -v openssl >/dev/null 2>&1; then
    NEW_TOKEN="$(openssl rand -hex 32)"
else
    NEW_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

if [[ -z "${NEW_TOKEN}" ]]; then
    echo "ERROR: failed to generate a new gateway token"
    exit 1
fi

echo "============================================"
echo "New gateway token generated."
echo "Save this token somewhere secure before proceeding:"
echo ""
echo "  ${NEW_TOKEN}"
echo ""
echo "============================================"
read -rp "Press Enter to apply the new token, or Ctrl+C to abort..."

# Update openclaw.json via openclaw CLI
# This updates the runtime config file at /home/openclaw/.openclaw/openclaw.json.
# Set both fields explicitly; do not rely on implicit mirroring.
su - openclaw -c "openclaw config set gateway.auth.token '${NEW_TOKEN}'"
su - openclaw -c "openclaw config set gateway.remote.token '${NEW_TOKEN}'"
echo "✓ Updated gateway.auth.token in openclaw.json"
echo "✓ Updated gateway.remote.token in openclaw.json"

# Ensure /opt/openclaw.env does not override gateway auth and has service kind
if grep -q '^OPENCLAW_GATEWAY_TOKEN=' /opt/openclaw.env; then
    sed -i '/^OPENCLAW_GATEWAY_TOKEN=/d' /opt/openclaw.env
    echo "✓ Removed OPENCLAW_GATEWAY_TOKEN from /opt/openclaw.env"
else
    echo "✓ OPENCLAW_GATEWAY_TOKEN already absent from /opt/openclaw.env"
fi

if grep -q '^OPENCLAW_SERVICE_KIND=' /opt/openclaw.env; then
    sed -i 's/^OPENCLAW_SERVICE_KIND=.*/OPENCLAW_SERVICE_KIND=gateway/' /opt/openclaw.env
else
    echo 'OPENCLAW_SERVICE_KIND=gateway' >> /opt/openclaw.env
fi
echo "✓ Ensured OPENCLAW_SERVICE_KIND=gateway in /opt/openclaw.env"

# Update gateway-token.txt only as a legacy convenience file.
echo "${NEW_TOKEN}" > /home/openclaw/.openclaw/gateway-token.txt
chmod 600 /home/openclaw/.openclaw/gateway-token.txt
chown openclaw:openclaw /home/openclaw/.openclaw/gateway-token.txt
echo "✓ Updated ~/.openclaw/gateway-token.txt (legacy convenience copy)"

# Record rotation date for sls-openclaw-system age monitoring
STATE_DIR="/home/openclaw/.openclaw/workspace/state/openclaw"
mkdir -p "${STATE_DIR}"
printf '{\n  "last_rotated": "%s",\n  "method": "rotate-openclaw-gateway.sh"\n}\n' \
    "$(date -u +%Y-%m-%d)" > "${STATE_DIR}/gateway-token.json"
chown -R openclaw:openclaw "${STATE_DIR}"
echo "✓ Updated state/openclaw/gateway-token.json (rotation date recorded)"

# Restart the gateway service to pick up the new token
systemctl restart openclaw
echo "✓ Gateway restarted"

# Verify the live process env did not pick up a stray gateway token
MAIN_PID=$(systemctl show openclaw -p MainPID --value)
if tr '\0' '\n' < "/proc/${MAIN_PID}/environ" | grep -q '^OPENCLAW_GATEWAY_TOKEN='; then
    echo "ERROR: live process still has OPENCLAW_GATEWAY_TOKEN in its environment"
    exit 1
fi
echo "✓ Verified live process has no OPENCLAW_GATEWAY_TOKEN override"

echo ""
echo "============================================"
echo "Token rotation complete."
echo ""
echo "NEXT STEPS:"
echo "  1. Verify devices still connected: openclaw devices list"
echo "  2. Run harvest to capture updated state:"
echo "     sudo bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh"
echo "  3. Commit the harvest snapshot"
echo "============================================"
