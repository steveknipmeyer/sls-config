#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
APT_MANIFEST="$CONFIG_DIR/packages/apt-required.txt"
PIPX_MANIFEST="$CONFIG_DIR/packages/pipx-tools.txt"
OPENCLAW_HOME=/home/openclaw
PIPX_HOME=/home/openclaw/.local/pipx
PIPX_BIN_DIR=/home/openclaw/.local/bin

if ! [[ ${EUID} -eq 0 ]]; then
    printf 'ERROR: run this bootstrap as root\n' >&2
    exit 1
fi

if ! id openclaw >/dev/null 2>&1; then
    printf 'ERROR: required user openclaw does not exist\n' >&2
    exit 1
fi

read_manifest() {
    local manifest=$1

    sed -E '/^[[:space:]]*(#|$)/d' "$manifest"
}

mapfile -t apt_packages < <(read_manifest "$APT_MANIFEST")
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "${apt_packages[@]}"

install -d -o openclaw -g openclaw -m 0755 "$PIPX_HOME" "$PIPX_BIN_DIR"

run_pipx() {
    runuser -u openclaw -- env \
        HOME="$OPENCLAW_HOME" \
        PIPX_HOME="$PIPX_HOME" \
        PIPX_BIN_DIR="$PIPX_BIN_DIR" \
        pipx "$@"
}

while IFS= read -r requirement || [[ -n "$requirement" ]]; do
    package=${requirement%%==*}
    expected_version=${requirement#*==}
    installed_version=$(
        run_pipx runpip "$package" show "$package" 2>/dev/null |
            sed -n 's/^Version: //p' || true
    )

    if [[ "$installed_version" == "$expected_version" ]]; then
        printf '%s %s is already installed\n' "$package" "$expected_version"
        continue
    fi

    run_pipx install --force "$requirement"
done < <(read_manifest "$PIPX_MANIFEST")

for tool in black ruff; do
    if ! [[ -x "$PIPX_BIN_DIR/$tool" ]]; then
        printf 'ERROR: expected executable is missing: %s/%s\n' \
            "$PIPX_BIN_DIR" "$tool" >&2
        exit 1
    fi
    "$PIPX_BIN_DIR/$tool" --version
done
