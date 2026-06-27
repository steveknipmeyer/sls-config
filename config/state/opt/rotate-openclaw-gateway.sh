#!/usr/bin/env bash
# =============================================================================
# rotate-openclaw-gateway.sh — Gateway Token Rotation Script
# =============================================================================
#
# PURPOSE:
#   Rotates the OpenClaw gateway authentication token.
#
#   Current sls policy:
#     1. ~/.openclaw/openclaw.json      — must keep SecretRef objects only
#        for gateway.auth.token and gateway.remote.token
#     2. /etc/openclaw-gateway.env      — sole file authority for
#        OPENCLAW_GATEWAY_TOKEN and OPENCLAW_REMOTE_TOKEN
#     3. /opt/openclaw.env              — must NOT contain gateway tokens;
#        should contain OPENCLAW_SERVICE_KIND=gateway
#     4. /etc/sls-web-server.env        — must NOT contain gateway tokens
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

OPENCLAW_HOME="/home/openclaw/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_HOME}/openclaw.json"
GATEWAY_ENV_FILE="/etc/openclaw-gateway.env"
WEB_ENV_FILE="/etc/sls-web-server.env"
OPENCLAW_ENV_FILE="/opt/openclaw.env"
LEGACY_TOKEN_FILE="REDACTED"
STATE_DIR="${OPENCLAW_HOME}/workspace/state/openclaw"

require_rw_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "ERROR: $file not found"
        exit 1
    fi
    if [[ ! -r "$file" || ! -w "$file" ]]; then
        echo "ERROR: $file must be readable and writable"
        exit 1
    fi
}

upsert_env_var() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

delete_env_var() {
    local file="$1" key="$2"
    if [[ -f "$file" ]] && grep -q "^${key}=" "$file"; then
        sed -i "/^${key}=/d" "$file"
        return 0
    fi
    return 1
}

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
echo "Token value is not printed to reduce terminal exposure."
echo "============================================"
read -rp "Press Enter to apply the new token, or Ctrl+C to abort..."

require_rw_file "$GATEWAY_ENV_FILE"
require_rw_file "$OPENCLAW_ENV_FILE"

# Refuse to proceed if openclaw.json gateway fields are not SecretRefs.
python3 - "$OPENCLAW_CONFIG_FILE" <<'PY'
import json
import sys

config_path = sys.argv[1]

with open(config_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

def read_path(obj, path):
    cur = obj
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur

def validate_secretref(name, value, expected_id):
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: {name} must be a SecretRef object")
    source = str(value.get("source", "")).strip()
    provider = str(value.get("provider", "")).strip()
    secret_id = str(value.get("id", "")).strip()
    if source != "env" or provider != "default" or secret_id != expected_id:
        raise SystemExit(
            f"ERROR: {name} must equal {{source:'env', provider:'default', id:'{expected_id}'}}"
        )

auth_token = read_path(cfg, ["gateway", "auth", "token"])
remote_token = read_path(cfg, ["gateway", "remote", "token"])

validate_secretref("gateway.auth.token", auth_token, "OPENCLAW_GATEWAY_TOKEN")
validate_secretref("gateway.remote.token", remote_token, "OPENCLAW_REMOTE_TOKEN")
PY
echo "✓ Verified openclaw.json gateway token fields are SecretRefs"

# Rotate canonical token authority in /etc/openclaw-gateway.env only.
upsert_env_var "$GATEWAY_ENV_FILE" "OPENCLAW_GATEWAY_TOKEN" "$NEW_TOKEN"
upsert_env_var "$GATEWAY_ENV_FILE" "OPENCLAW_REMOTE_TOKEN" "$NEW_TOKEN"
echo "✓ Rotated OPENCLAW_GATEWAY_TOKEN and OPENCLAW_REMOTE_TOKEN in /etc/openclaw-gateway.env"

# Remove gateway token duplication from web server env.
if [[ -f "$WEB_ENV_FILE" ]]; then
    removed_web=0
    if delete_env_var "$WEB_ENV_FILE" "OPENCLAW_GATEWAY_TOKEN"; then
        removed_web=1
    fi
    if delete_env_var "$WEB_ENV_FILE" "OPENCLAW_REMOTE_TOKEN"; then
        removed_web=1
    fi
    if [[ "$removed_web" -eq 1 ]]; then
        echo "✓ Removed gateway token entries from /etc/sls-web-server.env"
    else
        echo "✓ /etc/sls-web-server.env already has no gateway token entries"
    fi
else
    echo "✓ /etc/sls-web-server.env not present; no gateway token cleanup needed"
fi

# Ensure /opt/openclaw.env does not override gateway auth and has service kind.
if delete_env_var "$OPENCLAW_ENV_FILE" "OPENCLAW_GATEWAY_TOKEN"; then
    echo "✓ Removed OPENCLAW_GATEWAY_TOKEN from /opt/openclaw.env"
else
    echo "✓ OPENCLAW_GATEWAY_TOKEN already absent from /opt/openclaw.env"
fi

if delete_env_var "$OPENCLAW_ENV_FILE" "OPENCLAW_REMOTE_TOKEN"; then
    echo "✓ Removed OPENCLAW_REMOTE_TOKEN from /opt/openclaw.env"
else
    echo "✓ OPENCLAW_REMOTE_TOKEN already absent from /opt/openclaw.env"
fi

if grep -q '^OPENCLAW_SERVICE_KIND=' "$OPENCLAW_ENV_FILE"; then
    sed -i 's/^OPENCLAW_SERVICE_KIND=.*/OPENCLAW_SERVICE_KIND=gateway/' "$OPENCLAW_ENV_FILE"
else
    echo 'OPENCLAW_SERVICE_KIND=gateway' >> "$OPENCLAW_ENV_FILE"
fi
echo "✓ Ensured OPENCLAW_SERVICE_KIND=gateway in /opt/openclaw.env"

# Delete legacy convenience token file.
if [[ -f "$LEGACY_TOKEN_FILE" ]]; then
    rm -f "$LEGACY_TOKEN_FILE"
    echo "✓ Deleted legacy token file ~/.openclaw/gateway-token.txt"
else
    echo "✓ Legacy token file ~/.openclaw/gateway-token.txt already absent"
fi

# Record rotation date for sls-openclaw-system age monitoring
mkdir -p "${STATE_DIR}"
printf '{\n  "last_rotated": "%s",\n  "method": "rotate-openclaw-gateway.sh"\n}\n' \
    "$(date -u +%Y-%m-%d)" > "${STATE_DIR}/gateway-token.json"
chown -R openclaw:openclaw "${STATE_DIR}"
echo "✓ Updated state/openclaw/gateway-token.json (rotation date recorded)"

# Restart the gateway service to pick up the new token
systemctl restart openclaw
echo "✓ Gateway restarted"

# Restart web server so /openclaw/exec picks up the new token
systemctl restart sls-web-server
echo "✓ sls-web-server restarted"

# Verify gateway runtime picks up the rotated token from /etc/openclaw-gateway.env
MAIN_PID=$(systemctl show openclaw -p MainPID --value)
LIVE_GATEWAY_TOKEN=REDACTED
if [[ -z "${LIVE_GATEWAY_TOKEN}" ]]; then
    echo "ERROR: live openclaw process is missing OPENCLAW_GATEWAY_TOKEN"
    exit 1
fi
if [[ "${LIVE_GATEWAY_TOKEN}" != "${NEW_TOKEN}" ]]; then
    echo "ERROR: live openclaw OPENCLAW_GATEWAY_TOKEN does not match rotated value"
    exit 1
fi

LIVE_REMOTE_TOKEN=REDACTED
if [[ -z "${LIVE_REMOTE_TOKEN}" ]]; then
    echo "ERROR: live openclaw process is missing OPENCLAW_REMOTE_TOKEN"
    exit 1
fi
if [[ "${LIVE_REMOTE_TOKEN}" != "${NEW_TOKEN}" ]]; then
    echo "ERROR: live openclaw OPENCLAW_REMOTE_TOKEN does not match rotated value"
    exit 1
fi
echo "✓ Verified live openclaw process tokens match /etc/openclaw-gateway.env"

# Verify web server sees rotated token via /etc/openclaw-gateway.env
WEB_PID=$(systemctl show sls-web-server -p MainPID --value)
WEB_TOKEN=REDACTED
if [[ -z "${WEB_TOKEN}" ]]; then
    echo "ERROR: sls-web-server process is missing OPENCLAW_GATEWAY_TOKEN"
    exit 1
fi
if [[ "${WEB_TOKEN}" != "${NEW_TOKEN}" ]]; then
    echo "ERROR: sls-web-server OPENCLAW_GATEWAY_TOKEN does not match rotated value"
    exit 1
fi
echo "✓ Verified sls-web-server process token matches /etc/openclaw-gateway.env"

# Verify no token duplication remains in /etc/sls-web-server.env
if [[ -f "$WEB_ENV_FILE" ]] && (grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$WEB_ENV_FILE" || grep -q '^OPENCLAW_REMOTE_TOKEN=' "$WEB_ENV_FILE"); then
    echo "ERROR: /etc/sls-web-server.env still contains gateway token entries"
    exit 1
fi
echo "✓ Verified /etc/sls-web-server.env has no gateway token duplication"

echo ""
echo "============================================"
echo "Token rotation complete."
echo ""
echo "NEXT STEPS:"
echo "  1. Verify devices still connected: openclaw devices list"
echo "  2. Verify host exec route: /opt/openclaw-exec.sh devices list"
echo "  3. Verify token authority files:"
echo "     rg '^OPENCLAW_(GATEWAY|REMOTE)_TOKEN=' /etc/openclaw-gateway.env"
echo "     rg '^OPENCLAW_(GATEWAY|REMOTE)_TOKEN=' /etc/sls-web-server.env || true"
echo "     rg '^OPENCLAW_(GATEWAY|REMOTE)_TOKEN=' /opt/openclaw.env || true"
echo "============================================"
