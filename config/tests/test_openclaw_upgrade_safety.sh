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

accessible_cwd_line=$(line_number '^cd -- /home/openclaw$' "$UPGRADE_SCRIPT")
run_openclaw_line=$(line_number '^run_openclaw()' "$UPGRADE_SCRIPT")
[[ -n "$accessible_cwd_line" ]] || \
    fail "upgrade must enter an accessible service-user working directory"
[[ -n "$run_openclaw_line" ]] || fail "upgrade must define the service-user wrapper"
(( accessible_cwd_line < run_openclaw_line )) || \
    fail "accessible working directory must be established before service-user launches"

grep -qx 'RestartPreventExitStatus=78' "$SERVICE_UNIT" || \
    fail "systemd unit must suppress restarts after EX_CONFIG"

grep -q 'openclaw backup create .*--verify' "$UPGRADE_SCRIPT" || \
    fail "upgrade must create a verified backup"

if grep -q 'openclaw backup create --only-config' "$UPGRADE_SCRIPT"; then
    fail "config-only backup is insufficient before SQLite migrations"
fi

grep -q -- '--prepare' "$UPGRADE_SCRIPT" || \
    fail "upgrade must separate backup preparation from package execution"

grep -q -- '--execute' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require an explicit post-copy execution mode"

grep -q 'OFF_HOST_SHA256' "$UPGRADE_SCRIPT" || \
    fail "execution must require the checksum observed on the off-host copy"

grep -q 'os.O_NOFOLLOW' "$UPGRADE_SCRIPT" || \
    fail "execution must pin the selected archive without following symlinks"

grep -q 'verifier_path = f"/proc/{os.getpid()}/fd/{archive_fd}"' "$UPGRADE_SCRIPT" || \
    fail "vendor verification must address the descriptor through its owning process"

grep -Fq '["/usr/bin/openclaw", "backup", "verify", verifier_path]' "$UPGRADE_SCRIPT" || \
    fail "vendor verification must use the stable owner-process descriptor path"

if grep -q 'backup.*verify.*proc/self/fd\|f"/proc/self/fd/{archive_fd}"' "$UPGRADE_SCRIPT"; then
    fail "vendor verification must not use a collision-prone child-local descriptor path"
fi

backup_line=$(line_number 'openclaw backup create .*--verify' "$UPGRADE_SCRIPT")
stop_line=$(line_number 'systemctl stop openclaw' "$UPGRADE_SCRIPT")
install_line=$(line_number 'npm install -g' "$UPGRADE_SCRIPT")
update_repair_line=$(line_number 'openclaw update repair --yes --no-restart' "$UPGRADE_SCRIPT")
doctor_fix_line=$(line_number 'openclaw doctor --fix' "$UPGRADE_SCRIPT")
posture_line=$(line_number 'Applying approved security posture' "$UPGRADE_SCRIPT")
posture_validate_line=$(line_number 'openclaw config validate' "$UPGRADE_SCRIPT")
start_line=$(line_number 'systemctl start openclaw' "$UPGRADE_SCRIPT")
post_upgrade_line=$(line_number 'openclaw doctor --post-upgrade' "$UPGRADE_SCRIPT")
pipeline_replay_line=$(line_number 'cron/run-morning-pipeline.sh' "$UPGRADE_SCRIPT")
scheduled_proof_line=$(line_number 'cron/verify-scheduled-cron-success.sh.*--since-iso' "$UPGRADE_SCRIPT")
complete_line=$(line_number 'Live upgrade validation complete' "$UPGRADE_SCRIPT")

[[ -n "$backup_line" ]] || fail "upgrade must create a backup"
[[ -n "$stop_line" ]] || fail "upgrade must stop the gateway"
[[ -n "$install_line" ]] || fail "upgrade must install the target package"
[[ -n "$update_repair_line" ]] || fail "upgrade must run supported post-core update repair"
[[ -n "$doctor_fix_line" ]] || fail "upgrade must run offline Doctor repairs"
[[ -n "$posture_line" ]] || fail "upgrade must preserve the approved security posture"
[[ -n "$posture_validate_line" ]] || fail "upgrade must validate config after preserving security posture"
[[ -n "$start_line" ]] || fail "upgrade must start the gateway"
[[ -n "$post_upgrade_line" ]] || fail "upgrade must run post-upgrade checks"
[[ -n "$pipeline_replay_line" ]] || fail "upgrade must run the live morning pipeline replay"
[[ -n "$scheduled_proof_line" ]] || fail "upgrade must print the scheduled-proof follow-up command"
[[ -n "$complete_line" ]] || fail "upgrade must have a completion boundary"

(( backup_line < stop_line )) || fail "backup must finish before gateway shutdown"
(( stop_line < install_line )) || fail "gateway must stop before package replacement"
(( install_line < update_repair_line )) || fail "update repair must use the new package"
(( update_repair_line < doctor_fix_line )) || fail "update repair must precede standalone Doctor fallback"
(( install_line < doctor_fix_line )) || fail "Doctor repairs must use the new package"
(( doctor_fix_line < start_line )) || fail "Doctor repairs must finish before gateway startup"
(( doctor_fix_line < posture_line )) || fail "security posture must use the upgraded config schema"
(( posture_line < posture_validate_line )) || fail "security posture must be validated after writing"
(( posture_validate_line < start_line )) || fail "security posture must validate before gateway startup"
(( start_line < post_upgrade_line )) || fail "post-upgrade checks require the running gateway"
(( post_upgrade_line < pipeline_replay_line )) || fail "live replay must follow post-upgrade checks"
(( pipeline_replay_line < complete_line )) || fail "live validation cannot complete before replay passes"
(( complete_line < scheduled_proof_line )) || fail "scheduled-proof follow-up must be printed after live validation"

if grep -q 'Upgrade complete!' "$UPGRADE_SCRIPT"; then
    fail "upgrade must not claim full completion before scheduled proof passes"
fi

grep -q 'openclaw doctor --post-upgrade' "$UPGRADE_SCRIPT" || \
    fail "upgrade must run post-upgrade plugin compatibility checks"

grep -Fq 'run_openclaw update repair --yes --no-restart' "$UPGRADE_SCRIPT" || \
    fail "post-core repair must preserve external activation ownership"

grep -Fq "grep -Fq '[config] warnings: plugins.entries.codex:'" "$UPGRADE_SCRIPT" || \
    fail "update repair detection must require an active Codex migration warning"

if grep -q 'Update repair is still required' "$UPGRADE_SCRIPT"; then
    fail "successful update repair must not be rejected by historical Doctor warnings"
fi

grep -Fq '{"path":"tools.swarm","value":false}' "$UPGRADE_SCRIPT" || \
    fail "upgrade must explicitly disable default-on Swarm"

grep -Fq '{"path":"tools.sessions.visibility","value":"agent"}' "$UPGRADE_SCRIPT" || \
    fail "upgrade must limit session visibility to the current agent"

grep -Fq '{"path":"tools.agentToAgent.enabled","value":false}' "$UPGRADE_SCRIPT" || \
    fail "upgrade must explicitly disable ordinary cross-agent access"

grep -Fq 'config set --batch-json "$SECURITY_POSTURE_BATCH" --dry-run' "$UPGRADE_SCRIPT" || \
    fail "security-posture batch must pass a schema-validating dry run"

grep -Fxq 'run_openclaw config set --batch-json "$SECURITY_POSTURE_BATCH"' "$UPGRADE_SCRIPT" || \
    fail "security-posture settings must be written atomically"

grep -q 'OPENCLAW_SERVICE_REPAIR_POLICY:-.*external' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require the external service repair policy"

grep -q 'cmp -s /opt/openclaw-cli.sh.*config/state/opt/openclaw-cli.sh' "$UPGRADE_SCRIPT" || \
    fail "upgrade must refuse operator-wrapper drift"

grep -q 'cmp -s /etc/systemd/system/openclaw.service.*config/state/systemd/openclaw.service' "$UPGRADE_SCRIPT" || \
    fail "upgrade must refuse external service-unit drift"

grep -q 'systemctl show openclaw.*User.*openclaw' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require the openclaw service user"

grep -q 'systemctl show openclaw.*Group.*openclaw' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require the openclaw service group"

grep -q 'systemctl show openclaw.*ExecStart.*/usr/bin/openclaw gateway' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require the external gateway executable contract"

grep -q 'source "$OPENCLAW_ENV_FILE"\|source "$env_file"' "$UPGRADE_SCRIPT" || \
    fail "upgrade must load the root-managed OpenClaw environment"

grep -q 'source "$GATEWAY_ENV_FILE"\|source "$env_file"' "$UPGRADE_SCRIPT" || \
    fail "upgrade must load the root-managed gateway environment"

grep -Fq 'env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND' "$UPGRADE_SCRIPT" || \
    fail "service-user launches must strip sudo provenance before invoking OpenClaw"

grep -Fq 'for key in ("SUDO_USER", "SUDO_UID", "SUDO_GID", "SUDO_COMMAND"):' "$UPGRADE_SCRIPT" || \
    fail "Python-owned OpenClaw launches must strip sudo provenance"

grep -q 'verify_backup_proof \\' "$UPGRADE_SCRIPT" && \
    grep -q '"$RESUME_AFTER_INSTALL"' "$UPGRADE_SCRIPT" && \
    grep -q '"$EXPECTED_PREDECESSOR_VERSION"' "$UPGRADE_SCRIPT" || \
    fail "backup verification must scope legacy compatibility to resume mode and the approved predecessor"

grep -Fq 'f"openclaw@{predecessor_version}"' "$UPGRADE_SCRIPT" && \
    grep -q '"--ignore-scripts"' "$UPGRADE_SCRIPT" || \
    fail "legacy verification must install only the exact predecessor into temporary storage"

grep -Fq 'if legacy_package_version != predecessor_version:' "$UPGRADE_SCRIPT" || \
    fail "legacy verification must assert the downloaded package version"

if grep -qE '(^|[=([:space:]])openclaw (doctor|plugins|gateway|backup|--version)' "$UPGRADE_SCRIPT"; then
    fail "OpenClaw CLI calls must use the service-user wrapper"
fi

grep -q 'SYSTEM_PACKAGE_VERSION.*usr/lib/node_modules/openclaw/package.json' "$UPGRADE_SCRIPT" || \
    fail "resume mode must verify the installed system package"

grep -q 'Installed package.*does not match target' "$UPGRADE_SCRIPT" || \
    fail "fresh install must verify the exact target package before Doctor"

grep -q 'NEW_CLI_SEMVER.*TARGET_VERSION' "$UPGRADE_SCRIPT" || \
    fail "upgrade must verify the exact target CLI before updating service environment"

grep -q 'systemctl is-active --quiet openclaw' "$UPGRADE_SCRIPT" || \
    fail "resume mode must refuse online state repairs"

grep -q 'stop_gateway_on_validation_error' "$UPGRADE_SCRIPT" || \
    fail "post-start validation failures must stop the gateway"

grep -Fq '/opt/protect-workspace.sh check-reset' "$UPGRADE_SCRIPT" || \
    fail "upgrade acceptance must restore workspace immutable protection"

protection_failure_block=$(sed -n '/WORKSPACE FILE PROTECTION CHECK FAILED/,/^[[:space:]]*fi$/p' "$UPGRADE_SCRIPT")
grep -q 'stop_gateway_on_validation_error' <<<"$protection_failure_block" || \
    fail "workspace protection failure must explicitly stop the gateway"

validation_trap_line=$(line_number 'trap stop_gateway_on_validation_error ERR INT TERM' "$UPGRADE_SCRIPT")
clear_validation_trap_line=$(line_number 'trap - ERR INT TERM' "$UPGRADE_SCRIPT")
[[ -n "$validation_trap_line" ]] || fail "gateway cleanup trap must be installed"
[[ -n "$clear_validation_trap_line" ]] || fail "gateway cleanup trap must be cleared after validation"
(( validation_trap_line < start_line )) || fail "gateway cleanup trap must protect startup"
(( validation_trap_line < post_upgrade_line )) || fail "cleanup trap must cover post-upgrade checks"
(( complete_line < clear_validation_trap_line )) || fail "cleanup trap cannot clear before live validation passes"

grep -q 'VALIDATION_PHASE' "$UPGRADE_SCRIPT" || \
    fail "gateway cleanup diagnostics must identify the failing acceptance phase"

grep -Fq "[0-9]+(-[0-9]+)?'" "$UPGRADE_SCRIPT" || \
    fail "version parsing must preserve npm correction suffixes"

grep -q '2026\.9\.2.*v22\.23\.2' "$UPGRADE_SCRIPT" || \
    fail "2026.9.2 upgrade must require the approved Node 22 baseline"

grep -q '2026\.9\.5.*v26\.' "$UPGRADE_SCRIPT" || \
    fail "2026.9.5 upgrade must require Node 26"

if grep -q "TARGET_VERSION.*latest\|latest).*TARGET_VERSION" "$UPGRADE_SCRIPT"; then
    fail "staged upgrades must reject the unpinned latest target"
fi

stage_validator=$(mktemp)
trap 'rm -f "$stage_validator"' EXIT
awk '/^validate_stage_combination\(\)/,/^}/' "$UPGRADE_SCRIPT" >"$stage_validator"
[[ -s "$stage_validator" ]] || fail "upgrade must expose its stage matrix as testable shell logic"
# shellcheck source=/dev/null
source "$stage_validator"

validate_stage_combination --prepare 2026.9.2 v22.23.2 2026.7.1-2 || \
    fail "approved 2026.9.2 preparation boundary was rejected"
validate_stage_combination --execute 2026.9.5 v26.1.0 2026.9.2 || \
    fail "approved 2026.9.5 execution boundary was rejected"
validate_stage_combination --resume-after-install 2026.9.2 v22.23.2 2026.9.2 || \
    fail "approved 2026.9.2 resume boundary was rejected"

if validate_stage_combination --execute 2026.9.2 v26.1.0 2026.7.1-2; then
    fail "2026.9.2 must be rejected on Node 26"
fi
if validate_stage_combination --execute 2026.9.5 v22.23.2 2026.9.2; then
    fail "2026.9.5 must be rejected on Node 22"
fi
if validate_stage_combination --prepare 2026.9.5 v26.1.0 2026.7.1-2; then
    fail "2026.9.5 must reject the wrong predecessor core"
fi
if validate_stage_combination --prepare 2026.9.4 v26.1.0 2026.9.2; then
    fail "superseded 2026.9.4 target must be rejected"
fi
if validate_stage_combination --resume-after-install 2026.9.2 v22.23.2 2026.7.1-2; then
    fail "resume must reject a package that has not reached the target"
fi
if validate_stage_combination --prepare 2026.9.3 v22.23.2 2026.7.1-2; then
    fail "unapproved core targets must be rejected"
fi

grep -q 'NODE_EXECUTABLE_BEFORE_INSTALL=' "$UPGRADE_SCRIPT" || \
    fail "core upgrade must record the Node executable before package replacement"

grep -q 'NODE_VERSION_AFTER_INSTALL=' "$UPGRADE_SCRIPT" || \
    fail "core upgrade must verify Node after package replacement"

grep -q 'Node runtime changed during the core-only stage' "$UPGRADE_SCRIPT" || \
    fail "core upgrade must abort if Node changes during package replacement"

if grep -q 'plugins update --all' "$UPGRADE_SCRIPT"; then
    fail "staged upgrades must not select unpinned plugin generations"
fi

grep -Fq 'plugins install "@openclaw/codex@${TARGET_VERSION}" --force --pin' "$UPGRADE_SCRIPT" || \
    fail "staged upgrade must install the exact matching Codex generation"

grep -q '\.install.spec // empty' "$UPGRADE_SCRIPT" || \
    fail "staged upgrade must read the Codex install spec"

grep -Fq '[[ "$CODEX_SPEC" != "@openclaw/codex@${TARGET_VERSION}" ]]' "$UPGRADE_SCRIPT" || \
    fail "staged upgrade must compare the exact Codex install spec"

grep -q 'Connectivity probe: ok' "$UPGRADE_SCRIPT" || \
    fail "upgrade must require a successful Gateway connectivity probe"

printf 'PASS: OpenClaw upgrade safety invariants\n'