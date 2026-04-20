#!/usr/bin/env bash
# =============================================================================
# rotate-openclaw-gateway.sh — Gateway Token Rotation Script
# =============================================================================
#
# PURPOSE:
#   Rotates the OpenClaw gateway authentication token. The token must be
#   updated in three places to keep them in sync:
#     1. /opt/openclaw.env              — loaded by systemd at service start
#     2. ~/.openclaw/openclaw.json      — runtime config (gateway.auth.token
#                                         and gateway.remote.token)
#     3. ~/.openclaw/gateway-token.txt  — convenience file created by installer
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
NEW_TOKEN=REDACTED rand -hex 32)

echo "============================================"
echo "New gateway token generated."
echo "Save this token somewhere secure before proceeding:"
echo ""
echo "  ${NEW_TOKEN}"
echo ""
echo "============================================"
read -rp "Press Enter to apply the new token, or Ctrl+C to abort..."

# Update /opt/openclaw.env
if grep -q "^OPENCLAW_GATEWAY_TOKEN=" /opt/openclaw.env; then
    sed -i "s/^OPENCLAW_GATEWAY_TOKEN=REDACTED" /opt/openclaw.env
    echo "✓ Updated /opt/openclaw.env"
else
    echo "WARNING: OPENCLAW_GATEWAY_TOKEN not found in /opt/openclaw.env — adding it"
    echo "OPENCLAW_GATEWAY_TOKEN=REDACTED" >> /opt/openclaw.env
fi

# Update openclaw.json via openclaw CLI
# This updates the runtime config file at /home/openclaw/.openclaw/openclaw.json
su - openclaw -c "openclaw config set gateway.auth.token '${NEW_TOKEN}'"
echo "✓ Updated gateway.auth.token in openclaw.json"

# Update gateway-token.txt (convenience file created by DigitalOcean installer)
echo "${NEW_TOKEN}" > /home/openclaw/.openclaw/gateway-token.txt
chmod 600 /home/openclaw/.openclaw/gateway-token.txt
chown openclaw:openclaw /home/openclaw/.openclaw/gateway-token.txt
echo "✓ Updated ~/.openclaw/gateway-token.txt"

# Record rotation date for sls-openclaw-system age monitoring
STATE_DIR="/home/openclaw/.openclaw/workspaces/ada/state/openclaw"
mkdir -p "${STATE_DIR}"
printf '{\n  "last_rotated": "%s",\n  "method": "rotate-openclaw-gateway.sh"\n}\n' \
    "$(date -u +%Y-%m-%d)" > "${STATE_DIR}/gateway-token.json"
chown -R openclaw:openclaw "${STATE_DIR}"
echo "✓ Updated state/openclaw/gateway-token.json (rotation date recorded)"

# Restart the gateway service to pick up the new token
systemctl restart openclaw
echo "✓ Gateway restarted"

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
