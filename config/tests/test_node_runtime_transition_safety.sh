#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=$(cd -- "$SCRIPT_DIR/../state" && pwd)
TRANSITION_SCRIPT="$STATE_DIR/usr/local/libexec/sls/transition-node-runtime.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -f "$TRANSITION_SCRIPT" ]] || fail "Node transition helper is missing"
bash -n "$TRANSITION_SCRIPT" || fail "Node transition helper has invalid shell syntax"

grep -Fq 'TARGET_NODE_PACKAGE="26.8.2-1nodesource1"' "$TRANSITION_SCRIPT" || \
    fail "Node 26 package must be pinned exactly"
grep -Fq 'ROLLBACK_NODE_PACKAGE="22.23.2-1nodesource1"' "$TRANSITION_SCRIPT" || \
    fail "Node 22 rollback package must be pinned exactly"
grep -Fq 'TARGET_REPOSITORY="https://deb.nodesource.com/node_26.x"' "$TRANSITION_SCRIPT" || \
    fail "Node 26 repository prefix must be pinned"
grep -Fq 'ROLLBACK_REPOSITORY="https://deb.nodesource.com/node_22.x"' "$TRANSITION_SCRIPT" || \
    fail "Node 22 rollback repository prefix must be pinned"

grep -Fq 'NODESOURCE_KEYRING="/usr/share/keyrings/nodesource.gpg"' "$TRANSITION_SCRIPT" && \
    grep -q 'gpgv --status-fd 1 --keyring "$NODESOURCE_KEYRING"' "$TRANSITION_SCRIPT" || \
    fail "NodeSource InRelease metadata must be signature-verified"
grep -Fq 'NODESOURCE_SIGNING_FINGERPRINT="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"' \
    "$TRANSITION_SCRIPT" || fail "NodeSource signing identity must be pinned"
grep -Fq 'fields.get("Filename"' "$TRANSITION_SCRIPT" || \
    fail "artifact path must come from signed package metadata"
grep -Fq 'fields.get("SHA256"' "$TRANSITION_SCRIPT" || \
    fail "artifact checksum must come from signed package metadata"
grep -Fq 'r" +([0-9a-f]{64}) +([0-9]+) +main/binary-amd64/Packages.gz"' \
    "$TRANSITION_SCRIPT" || fail "signed index parser must accept Debian checksum-table spacing"
grep -q 'sha256sum --check' "$TRANSITION_SCRIPT" || \
    fail "downloaded package checksum must be verified"

grep -q -- '--prepare' "$TRANSITION_SCRIPT" || \
    fail "helper must provide a non-mutating preparation mode"
grep -q -- '--execute' "$TRANSITION_SCRIPT" || \
    fail "helper must require an explicit execution mode"
grep -q -- '--rollback' "$TRANSITION_SCRIPT" || \
    fail "helper must provide an explicit rollback mode"
grep -q 'OFF_HOST_SHA256' "$TRANSITION_SCRIPT" || \
    fail "execution must require an off-host backup checksum"
grep -q 'os.O_NOFOLLOW' "$TRANSITION_SCRIPT" || \
    fail "backup verification must reject symlink substitution"
grep -Fq 'ROLLBACK_CACHE_DIR="/var/cache/sls/node-runtime-transition"' "$TRANSITION_SCRIPT" || \
    fail "execution must retain the verified rollback package outside temporary storage"
grep -q 'cache_rollback_package' "$TRANSITION_SCRIPT" || \
    fail "execution must cache the rollback package before Node replacement"
grep -q 'flock -n 9' "$TRANSITION_SCRIPT" || \
    fail "concurrent Node transitions must be rejected"

rollback_block=$(sed -n '/^    --rollback)/,/^        ;;/p' "$TRANSITION_SCRIPT")
if grep -q 'BACKUP_ARCHIVE\|OFF_HOST_SHA256' <<<"$rollback_block"; then
    fail "rollback must not depend on the potentially broken OpenClaw runtime"
fi

backup_line=$(grep -n -m1 'verify_backup_proof' "$TRANSITION_SCRIPT" | cut -d: -f1)
stop_line=$(grep -n -m1 'systemctl stop openclaw' "$TRANSITION_SCRIPT" | cut -d: -f1)
install_line=$(grep -n -m1 'dpkg --install' "$TRANSITION_SCRIPT" | cut -d: -f1)
[[ -n "$backup_line" && -n "$stop_line" && -n "$install_line" ]] || \
    fail "backup, shutdown, and package installation boundaries must exist"
(( backup_line < stop_line )) || fail "backup proof must precede gateway shutdown"
(( stop_line < install_line )) || fail "gateway must stop before Node replacement"

grep -Fq "EXPECTED_OPENCLAW_VERSION=\"2026.9.2\"" "$TRANSITION_SCRIPT" || \
    fail "Node transition must pin the bridge OpenClaw generation"
grep -Fq '@openclaw/codex@${EXPECTED_OPENCLAW_VERSION}' "$TRANSITION_SCRIPT" || \
    fail "Node transition must verify the exact bridge Codex generation"
if grep -qE 'npm (install|update).*openclaw|plugins install' "$TRANSITION_SCRIPT"; then
    fail "Node-only transition must not replace OpenClaw or Codex"
fi

grep -q 'cmp -s /etc/systemd/system/openclaw.service' "$TRANSITION_SCRIPT" || \
    fail "helper must reject external service-unit drift"
grep -q 'systemctl show openclaw.*User.*openclaw' "$TRANSITION_SCRIPT" || \
    fail "helper must preserve the openclaw service user"
grep -q 'systemctl show openclaw.*Group.*openclaw' "$TRANSITION_SCRIPT" || \
    fail "helper must preserve the openclaw service group"
grep -q 'systemctl show openclaw.*ExecStart.*/usr/bin/openclaw gateway' "$TRANSITION_SCRIPT" || \
    fail "helper must preserve the gateway executable contract"

grep -q 'process.versions.modules' "$TRANSITION_SCRIPT" || \
    fail "helper must record the Node ABI"
grep -q 'process.versions.sqlite' "$TRANSITION_SCRIPT" || \
    fail "helper must verify the linked SQLite version"
grep -q '\.node' "$TRANSITION_SCRIPT" || \
    fail "helper must inspect native addon binaries"
grep -Fq -- "-path '*linux-x64*' -o -path '*linux_x64*'" "$TRANSITION_SCRIPT" || \
    fail "native addon checks must select only the host architecture"
grep -q 'Connectivity probe: ok' "$TRANSITION_SCRIPT" || \
    fail "helper must require gateway connectivity"
grep -q 'stop_gateway_on_validation_error' "$TRANSITION_SCRIPT" || \
    fail "post-start failure must stop the gateway"
grep -q 'cron/run-morning-pipeline.sh' "$TRANSITION_SCRIPT" || \
    fail "helper must replay the production workflow"
grep -q 'verify-scheduled-cron-success.sh.*--since-iso' "$TRANSITION_SCRIPT" || \
    fail "helper must print the natural-cycle verification command"

if [[ $(id -u) -ne 0 ]]; then
    if bash "$TRANSITION_SCRIPT" --prepare >/dev/null 2>&1; then
        fail "non-root preparation must be rejected"
    fi
fi

printf 'PASS: Node runtime transition safety invariants\n'