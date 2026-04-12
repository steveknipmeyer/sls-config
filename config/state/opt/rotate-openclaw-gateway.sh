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
# NOTE ON openclaw.json SYMLINK:
#   /root/.openclaw/openclaw.json and /home/openclaw/.openclaw/openclaw.json
#   are the SAME FILE via symlink. Do NOT copy one to the other — it is
#   unnecessary and may break the symlink. The original version of this script
#   (generated Mar 29) incorrectly included a cp command; that has been removed.
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
# This updates the runtime config file at ~/.openclaw/openclaw.json
# (same file as /root/.openclaw/openclaw.json via symlink)
su - openclaw -c "openclaw config set gateway.auth.token '${NEW_TOKEN}'"
echo "✓ Updated gateway.auth.token in openclaw.json"

# Update gateway-token.txt (convenience file created by DigitalOcean installer)
echo "${NEW_TOKEN}" > /home/openclaw/.openclaw/gateway-token.txt
chmod 600 /home/openclaw/.openclaw/gateway-token.txt
chown openclaw:openclaw /home/openclaw/.openclaw/gateway-token.txt
echo "✓ Updated ~/.openclaw/gateway-token.txt"

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
echo "     sudo bash /home/openclaw/.openclaw/workspace/extras/scripts/harvest.sh"
echo "  3. Commit the harvest snapshot"
echo "============================================"
