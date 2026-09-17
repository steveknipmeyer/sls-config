#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

TARGET_NODE_PACKAGE="26.8.2-1nodesource1"
ROLLBACK_NODE_PACKAGE="22.23.2-1nodesource1"
TARGET_REPOSITORY="https://deb.nodesource.com/node_26.x"
ROLLBACK_REPOSITORY="https://deb.nodesource.com/node_22.x"
TARGET_PACKAGE_SHA256="2cc292ef98fadb477d4b5e23e503742b348a9e6576046eebc787ef3a370e531b"
ROLLBACK_PACKAGE_SHA256="eed0c5f0ab411f28783f81f051fcf7928ae8bf833e2df11f48f3fa78270025cb"
EXPECTED_OPENCLAW_VERSION="2026.9.2"
EXPECTED_NPM_PREFIX="/home/openclaw/.openclaw/workspace/npm"
NODESOURCE_KEYRING="/usr/share/keyrings/nodesource.gpg"
NODESOURCE_SIGNING_FINGERPRINT="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
NODESOURCE_SOURCE="/etc/apt/sources.list.d/nodesource.sources"
BACKUP_DIR="/home/openclaw/Backups/openclaw"
ROLLBACK_CACHE_DIR="/var/cache/sls/node-runtime-transition"
ROLLBACK_CACHE="$ROLLBACK_CACHE_DIR/nodejs_${ROLLBACK_NODE_PACKAGE}_amd64.deb"
LOCK_FILE="/run/lock/sls-node-runtime-transition.lock"
TRACKED_SERVICE="/home/openclaw/.openclaw/projects/sls-config/config/state/systemd/openclaw.service"
WORK_DIR=""

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

require_root() {
    [[ $(id -u) -eq 0 ]] || fail "run this reviewed host transition as root"
}

require_commands() {
    local command_name

    for command_name in curl dpkg find flock gpgv gzip jq ldd node npm python3 sha256sum systemctl; do
        command -v "$command_name" >/dev/null || fail "required command is missing: $command_name"
    done
    [[ -r "$NODESOURCE_KEYRING" ]] || fail "NodeSource keyring is not readable"
}

acquire_transition_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || fail "another Node runtime transition is already running"
}

load_openclaw_environment() {
    local env_file

    for env_file in /opt/openclaw.env /etc/openclaw-gateway.env; do
        [[ -r "$env_file" ]] || fail "required environment file is not readable: $env_file"
        set -a
        # Root-managed systemd EnvironmentFile inputs are trusted host configuration.
        source "$env_file"
        set +a
    done

    [[ "${OPENCLAW_SERVICE_REPAIR_POLICY:-}" == "external" ]] || \
        fail "OPENCLAW_SERVICE_REPAIR_POLICY must remain external"
    [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]] || fail "gateway token is unavailable"
    export OPENCLAW_REMOTE_TOKEN="${OPENCLAW_REMOTE_TOKEN:-$OPENCLAW_GATEWAY_TOKEN}"
}

run_openclaw() {
    sudo -u openclaw -H \
        --preserve-env=OPENCLAW_GATEWAY_TOKEN,OPENCLAW_REMOTE_TOKEN,OPENCLAW_SERVICE_KIND,OPENCLAW_SERVICE_REPAIR_POLICY \
        env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
        /usr/bin/openclaw "$@"
}

verify_external_service_contract() {
    cmp -s /etc/systemd/system/openclaw.service "$TRACKED_SERVICE" || \
        fail "OpenClaw service unit differs from its reviewed snapshot"
    [[ "$(systemctl show openclaw -p User --value)" == "openclaw" ]] || \
        fail "OpenClaw service user changed"
    [[ "$(systemctl show openclaw -p Group --value)" == "openclaw" ]] || \
        fail "OpenClaw service group changed"
    systemctl show openclaw -p ExecStart --value | grep -Fq '/usr/bin/openclaw gateway' || \
        fail "OpenClaw service executable contract changed"
}

verify_openclaw_identity() {
    local codex_spec
    local package_version
    local prefix

    package_version=$(/usr/bin/node -p \
        "require('/usr/lib/node_modules/openclaw/package.json').version" 2>/dev/null || true)
    [[ "$package_version" == "$EXPECTED_OPENCLAW_VERSION" ]] || \
        fail "expected openclaw@${EXPECTED_OPENCLAW_VERSION}; found ${package_version:-unknown}"

    codex_spec=$(run_openclaw plugins inspect codex --json | jq -r '.install.spec // empty')
    [[ "$codex_spec" == "@openclaw/codex@${EXPECTED_OPENCLAW_VERSION}" ]] || \
        fail "Codex is not pinned to @openclaw/codex@${EXPECTED_OPENCLAW_VERSION}"

    prefix=$(sudo -u openclaw -H npm config get prefix)
    [[ "$prefix" == "$EXPECTED_NPM_PREFIX" ]] || \
        fail "openclaw npm prefix changed: ${prefix:-unknown}"
}

verify_backup_proof() {
    local backup_archive="$1"
    local expected_sha256="$2"

    sudo -u openclaw -H python3 - "$BACKUP_DIR" "$backup_archive" "$expected_sha256" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys

backup_dir = Path(sys.argv[1])
archive_path = Path(sys.argv[2])
expected_sha256 = sys.argv[3]

if not archive_path.is_absolute() or archive_path.parent != backup_dir:
    raise SystemExit(f"Backup archive must be directly inside {backup_dir}")
if len(expected_sha256) != 64 or any(c not in "0123456789abcdef" for c in expected_sha256):
    raise SystemExit("A lowercase SHA-256 observed on the off-host copy is required")

directory_fd = os.open(backup_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    archive_fd = os.open(archive_path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
finally:
    os.close(directory_fd)

try:
    if not stat.S_ISREG(os.fstat(archive_fd).st_mode):
        raise SystemExit("Backup archive is not a regular file")
    digest = hashlib.file_digest(os.fdopen(os.dup(archive_fd), "rb"), "sha256")
    if digest.hexdigest() != expected_sha256:
        raise SystemExit("Local and off-host backup checksums do not match")
    verifier_path = f"/proc/{os.getpid()}/fd/{archive_fd}"
    subprocess.run(["/usr/bin/openclaw", "backup", "verify", verifier_path], check=True)
finally:
    os.close(archive_fd)
PY
}

extract_signed_index_digest() {
    local inrelease="$1"

    python3 - "$inrelease" <<'PY'
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
in_sha256 = False
matches = []
for line in lines:
    if line == "SHA256:":
        in_sha256 = True
        continue
    if in_sha256 and line and not line.startswith(" "):
        break
    if in_sha256:
        match = re.fullmatch(r" +([0-9a-f]{64}) +([0-9]+) +main/binary-amd64/Packages.gz", line)
        if match:
            matches.append(match.groups())
if len(matches) != 1:
    raise SystemExit("signed InRelease does not uniquely identify Packages.gz")
print(*matches[0], sep="\t")
PY
}

extract_package_metadata() {
    local packages_file="$1"
    local expected_version="$2"

    python3 - "$packages_file" "$expected_version" <<'PY'
from pathlib import Path, PurePosixPath
import re
import sys

paragraphs = Path(sys.argv[1]).read_text(encoding="utf-8").split("\n\n")
expected_version = sys.argv[2]
matches = []
for paragraph in paragraphs:
    fields = {}
    for line in paragraph.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    if fields.get("Package") == "nodejs" and fields.get("Version") == expected_version:
        matches.append(fields)
if len(matches) != 1:
    raise SystemExit(f"signed index does not uniquely contain nodejs={expected_version}")

fields = matches[0]
if fields.get("Architecture") != "amd64":
    raise SystemExit("package architecture is not amd64")
filename = fields.get("Filename", "")
path = PurePosixPath(filename)
if path.is_absolute() or ".." in path.parts or not filename.startswith("pool/"):
    raise SystemExit("package Filename is outside the repository pool")
if not re.fullmatch(r"[0-9]+", fields.get("Size", "")):
    raise SystemExit("package Size is invalid")
if not re.fullmatch(r"[0-9a-f]{64}", fields.get("SHA256", "")):
    raise SystemExit("package SHA256 is invalid")
print(filename, fields["Size"], fields["SHA256"], sep="\t")
PY
}

fetch_verified_package() {
    local repository="$1"
    local package_version="$2"
    local reviewed_sha256="$3"
    local output_file="$4"
    local repository_dir="$5"
    local inrelease="$repository_dir/InRelease"
    local packages_gz="$repository_dir/Packages.gz"
    local packages_file="$repository_dir/Packages"
    local gpg_status
    local index_sha256 index_size filename package_size package_sha256

    mkdir -p -- "$repository_dir"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        --output "$inrelease" "$repository/dists/nodistro/InRelease"
    gpg_status=$(gpgv --status-fd 1 --keyring "$NODESOURCE_KEYRING" "$inrelease" 2>/dev/null)
    grep -Fq "[GNUPG:] VALIDSIG $NODESOURCE_SIGNING_FINGERPRINT " <<<"$gpg_status" || \
        fail "NodeSource InRelease signer fingerprint is not approved"

    IFS=$'\t' read -r index_sha256 index_size < <(extract_signed_index_digest "$inrelease")
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        --output "$packages_gz" "$repository/dists/nodistro/main/binary-amd64/Packages.gz"
    [[ "$(stat -c %s "$packages_gz")" == "$index_size" ]] || fail "Packages.gz size mismatch"
    printf '%s  %s\n' "$index_sha256" "$packages_gz" | sha256sum --check --status || \
        fail "Packages.gz checksum does not match signed InRelease"
    gzip -dc -- "$packages_gz" >"$packages_file"

    IFS=$'\t' read -r filename package_size package_sha256 < <(
        extract_package_metadata "$packages_file" "$package_version"
    )
    [[ "$package_sha256" == "$reviewed_sha256" ]] || \
        fail "signed package digest differs from the reviewed digest"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
        --output "$output_file" "$repository/$filename"
    [[ "$(stat -c %s "$output_file")" == "$package_size" ]] || fail "package size mismatch"
    printf '%s  %s\n' "$package_sha256" "$output_file" | sha256sum --check --status || \
        fail "downloaded package checksum does not match signed metadata"
}

write_nodesource_source() {
    local repository="$1"
    local source_file="$WORK_DIR/nodesource.sources"

    printf '%s\n' \
        'Types: deb' \
        "URIs: $repository" \
        'Suites: nodistro' \
        'Components: main' \
        'Architectures: amd64' \
        "Signed-By: $NODESOURCE_KEYRING" >"$source_file"
    install -o root -g root -m 0644 "$source_file" "$NODESOURCE_SOURCE"
}

verify_node_package() {
    local expected_package="$1"
    local expected_runtime="$2"
    local installed_package

    installed_package=$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)
    [[ "$installed_package" == "$expected_package" ]] || \
        fail "expected nodejs=${expected_package}; found ${installed_package:-unknown}"
    [[ "$(/usr/bin/node --version)" == "$expected_runtime" ]] || \
        fail "Node runtime does not match $expected_runtime"
    [[ "$(readlink -f /usr/bin/node)" == "/usr/bin/node" ]] || \
        fail "Node executable identity changed"
}

cache_rollback_package() {
    install -d -o root -g root -m 0700 "$ROLLBACK_CACHE_DIR"
    install -o root -g root -m 0600 "$WORK_DIR/node-22.deb" "$ROLLBACK_CACHE"
    printf '%s  %s\n' "$ROLLBACK_PACKAGE_SHA256" "$ROLLBACK_CACHE" | \
        sha256sum --check --status || fail "cached rollback package checksum mismatch"
}

prepare_rollback_package() {
    if [[ -f "$ROLLBACK_CACHE" ]] && \
        printf '%s  %s\n' "$ROLLBACK_PACKAGE_SHA256" "$ROLLBACK_CACHE" | \
            sha256sum --check --status; then
        install -m 0600 "$ROLLBACK_CACHE" "$WORK_DIR/node-22.deb"
        return
    fi

    fetch_verified_package \
        "$ROLLBACK_REPOSITORY" "$ROLLBACK_NODE_PACKAGE" "$ROLLBACK_PACKAGE_SHA256" \
        "$WORK_DIR/node-22.deb" "$WORK_DIR/node-22-repository"
}

verify_native_runtime() {
    local addon
    local addon_count=0

    /usr/bin/node -e 'if (!process.versions.modules) process.exit(1); console.log(`Node ABI: ${process.versions.modules}`)'
    /usr/bin/node -e 'if (!process.versions.sqlite) process.exit(1); console.log(`Linked SQLite: ${process.versions.sqlite}`)'
    while IFS= read -r -d '' addon; do
        addon_count=$((addon_count + 1))
        if ldd "$addon" | grep -Fq 'not found'; then
            fail "native addon has an unresolved library: $addon"
        fi
        /usr/bin/node -e 'process.dlopen({exports:{}}, process.argv[1])' "$addon" || \
            fail "native addon failed to load: $addon"
    done < <(
        find /usr/lib/node_modules/openclaw -type f -name '*.node' \
            \( -path '*linux-x64*' -o -path '*linux_x64*' \) \
            ! -path '*musl*' -print0
    )
    (( addon_count > 0 )) || fail "no host native addons were found"
    printf 'Loaded %d host native addons.\n' "$addon_count"
}

stop_gateway_on_validation_error() {
    local status=$?
    [[ $status -ne 0 ]] || status=1
    printf 'Acceptance failed during %s; stopping the Gateway.\n' "$VALIDATION_PHASE" >&2
    systemctl stop openclaw || true
    exit "$status"
}

validate_running_system() {
    local gateway_status=""
    local attempt

    verify_openclaw_identity
    verify_external_service_contract
    verify_native_runtime

    VALIDATION_PHASE="Gateway startup"
    trap stop_gateway_on_validation_error ERR INT TERM
    systemctl start openclaw
    VALIDATION_PHASE="Gateway connectivity"
    for attempt in {1..30}; do
        gateway_status=$(run_openclaw gateway status --deep 2>&1 || true)
        if grep -q 'Connectivity probe: ok' <<<"$gateway_status"; then
            break
        fi
        [[ $attempt -eq 30 ]] || sleep 2
    done
    printf '%s\n' "$gateway_status"
    grep -q 'Connectivity probe: ok' <<<"$gateway_status" || return 1
    VALIDATION_PHASE="post-transition Doctor"
    run_openclaw doctor --post-upgrade
    VALIDATION_PHASE="live morning pipeline replay"
    PIPELINE_REPLAY_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    /home/openclaw/.openclaw/cron/run-morning-pipeline.sh
    trap - ERR INT TERM

    echo "Immediate Node transition acceptance passed."
    echo "Natural scheduled-cycle proof remains pending. Verify it with:"
    echo "  /home/openclaw/.openclaw/cron/verify-scheduled-cron-success.sh --since-iso $PIPELINE_REPLAY_STARTED_AT"
}

usage() {
    echo "Usage: $0 --prepare"
    echo "       $0 --execute <backup-archive> <off-host-sha256>"
    echo "       $0 --rollback"
}

MODE="${1:-}"
shift || true
BACKUP_ARCHIVE=""
OFF_HOST_SHA256=""
case "$MODE" in
    --prepare)
        [[ $# -eq 0 ]] || { usage >&2; exit 1; }
        ;;
    --execute)
        [[ $# -eq 2 ]] || { usage >&2; exit 1; }
        BACKUP_ARCHIVE="$1"
        OFF_HOST_SHA256="$2"
        ;;
    --rollback)
        [[ $# -eq 0 ]] || { usage >&2; exit 1; }
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

require_root
require_commands
acquire_transition_lock
load_openclaw_environment
verify_external_service_contract
WORK_DIR=$(mktemp -d /var/tmp/node-runtime-transition.XXXXXX)

if [[ "$MODE" == "--prepare" ]]; then
    verify_openclaw_identity
    verify_node_package "$ROLLBACK_NODE_PACKAGE" "v22.23.2"
    fetch_verified_package \
        "$TARGET_REPOSITORY" "$TARGET_NODE_PACKAGE" "$TARGET_PACKAGE_SHA256" \
        "$WORK_DIR/node-26.deb" "$WORK_DIR/node-26-repository"
    prepare_rollback_package
    verify_native_runtime
    install -d -m 0700 -o openclaw -g openclaw "$BACKUP_DIR"
    BACKUP_ARCHIVE="$BACKUP_DIR/$(date -u +%Y-%m-%dT%H-%M-%SZ)-pre-node-26.tar.gz"
    run_openclaw backup create --output "$BACKUP_ARCHIVE" --verify
    echo "Prepared archive: $BACKUP_ARCHIVE"
    echo "On-host SHA-256: $(sha256sum "$BACKUP_ARCHIVE" | awk '{print $1}')"
    echo "Copy it off-host and verify the checksum there before --execute."
    exit 0
fi

if [[ "$MODE" == "--execute" ]]; then
    verify_openclaw_identity
    verify_node_package "$ROLLBACK_NODE_PACKAGE" "v22.23.2"
    fetch_verified_package \
        "$TARGET_REPOSITORY" "$TARGET_NODE_PACKAGE" "$TARGET_PACKAGE_SHA256" \
        "$WORK_DIR/node-26.deb" "$WORK_DIR/node-26-repository"
    prepare_rollback_package
    verify_backup_proof "$BACKUP_ARCHIVE" "$OFF_HOST_SHA256"
    echo "Node 26 is a non-LTS Current release. This stage changes only the Node runtime."
    read -r -p "Install exact nodejs=${TARGET_NODE_PACKAGE}? (y/n) " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || fail "operator declined Node 26 execution"
    cache_rollback_package
    systemctl stop openclaw
    dpkg --install "$WORK_DIR/node-26.deb"
    write_nodesource_source "$TARGET_REPOSITORY"
    verify_node_package "$TARGET_NODE_PACKAGE" "v26.8.2"
else
    prepare_rollback_package
    echo "Rollback restores exact nodejs=${ROLLBACK_NODE_PACKAGE}; OpenClaw data is unchanged."
    read -r -p "Roll back the Node runtime now? (y/n) " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || fail "operator declined Node rollback"
    systemctl stop openclaw
    dpkg --install "$WORK_DIR/node-22.deb"
    write_nodesource_source "$ROLLBACK_REPOSITORY"
    verify_node_package "$ROLLBACK_NODE_PACKAGE" "v22.23.2"
fi

validate_running_system