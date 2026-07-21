#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=$(cd -- "$SCRIPT_DIR/../state" && pwd)
UPGRADE_SCRIPT="$STATE_DIR/opt/complete-openclaw-upgrade.sh"
SERVICE_UNIT="$STATE_DIR/systemd/openclaw.service"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

line_number() {
    local pattern="$1"
    local file="$2"
    grep -n -m1 -- "$pattern" "$file" | cut -d: -f1 || true
}

grep -qx 'RestartPreventExitStatus=78' "$SERVICE_UNIT" || \
    fail "systemd unit must suppress restarts after EX_CONFIG"

grep -q 'openclaw backup create .*--verify' "$UPGRADE_SCRIPT" || \
    fail "upgrade must create a verified backup"

if grep -q 'openclaw backup create --only-config' "$UPGRADE_SCRIPT"; then
    fail "config-only backup is insufficient before SQLite migrations"
fi

backup_line=$(line_number 'openclaw backup create .*--verify' "$UPGRADE_SCRIPT")
stop_line=$(line_number 'systemctl stop openclaw' "$UPGRADE_SCRIPT")
install_line=$(line_number 'npm install -g' "$UPGRADE_SCRIPT")
doctor_fix_line=$(line_number 'openclaw doctor --fix' "$UPGRADE_SCRIPT")
start_line=$(line_number 'systemctl start openclaw' "$UPGRADE_SCRIPT")
post_upgrade_line=$(line_number 'openclaw doctor --post-upgrade' "$UPGRADE_SCRIPT")
pipeline_replay_line=$(line_number 'cron/run-morning-pipeline.sh' "$UPGRADE_SCRIPT")
scheduled_proof_line=$(line_number 'cron/verify-scheduled-cron-success.sh.*--since-iso' "$UPGRADE_SCRIPT")
complete_line=$(line_number 'Live upgrade validation complete' "$UPGRADE_SCRIPT")

[[ -n "$backup_line" ]] || fail "upgrade must create a backup"
[[ -n "$stop_line" ]] || fail "upgrade must stop the gateway"
[[ -n "$install_line" ]] || fail "upgrade must install the target package"
[[ -n "$doctor_fix_line" ]] || fail "upgrade must run offline Doctor repairs"
[[ -n "$start_line" ]] || fail "upgrade must start the gateway"
[[ -n "$post_upgrade_line" ]] || fail "upgrade must run post-upgrade checks"
[[ -n "$pipeline_replay_line" ]] || fail "upgrade must run the live morning pipeline replay"
[[ -n "$scheduled_proof_line" ]] || fail "upgrade must print the scheduled-proof follow-up command"
[[ -n "$complete_line" ]] || fail "upgrade must have a completion boundary"

(( backup_line < stop_line )) || fail "backup must finish before gateway shutdown"
(( stop_line < install_line )) || fail "gateway must stop before package replacement"
(( install_line < doctor_fix_line )) || fail "Doctor repairs must use the new package"
(( doctor_fix_line < start_line )) || fail "Doctor repairs must finish before gateway startup"
(( start_line < post_upgrade_line )) || fail "post-upgrade checks require the running gateway"
(( post_upgrade_line < pipeline_replay_line )) || fail "live replay must follow post-upgrade checks"
(( pipeline_replay_line < complete_line )) || fail "live validation cannot complete before replay passes"
(( complete_line < scheduled_proof_line )) || fail "scheduled-proof follow-up must be printed after live validation"

if grep -q 'Upgrade complete!' "$UPGRADE_SCRIPT"; then
    fail "upgrade must not claim full completion before scheduled proof passes"
fi

grep -q 'openclaw doctor --post-upgrade' "$UPGRADE_SCRIPT" || \
    fail "upgrade must run post-upgrade plugin compatibility checks"

grep -q 'OPENCLAW_SERVICE_REPAIR_POLICY:-.*external' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require the external service repair policy"

grep -q 'source "$OPENCLAW_ENV_FILE"\|source "$env_file"' "$UPGRADE_SCRIPT" || \
    fail "upgrade must load the root-managed OpenClaw environment"

grep -q 'source "$GATEWAY_ENV_FILE"\|source "$env_file"' "$UPGRADE_SCRIPT" || \
    fail "upgrade must load the root-managed gateway environment"

if grep -qE '(^|[=([:space:]])openclaw (doctor|plugins|gateway|backup|--version)' "$UPGRADE_SCRIPT"; then
    fail "OpenClaw CLI calls must use the service-user wrapper"
fi

grep -q 'SYSTEM_PACKAGE_VERSION.*usr/lib/node_modules/openclaw/package.json' "$UPGRADE_SCRIPT" || \
    fail "resume mode must verify the installed system package"

grep -q 'systemctl is-active --quiet openclaw' "$UPGRADE_SCRIPT" || \
    fail "resume mode must refuse online state repairs"

grep -Fq "[0-9]+(-[0-9]+)?'" "$UPGRADE_SCRIPT" || \
    fail "version parsing must preserve npm correction suffixes"

grep -q 'Connectivity probe: ok' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require a successful Gateway connectivity probe"

printf 'PASS: OpenClaw upgrade safety invariants\n'