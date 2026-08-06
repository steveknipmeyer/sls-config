#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PLUGIN_MANIFEST="$CONFIG_DIR/packages/openclaw-plugins.txt"

if ! [[ ${EUID} -ne 0 ]]; then
    printf 'ERROR: run this bootstrap as the openclaw user, not root\n' >&2
    exit 1
fi

if [[ $(id -un) != openclaw ]]; then
    printf 'ERROR: run this bootstrap as the openclaw user\n' >&2
    exit 1
fi

for command in jq openclaw; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'ERROR: required command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

read_manifest() {
    sed -E '/^[[:space:]]*(#|$)/d' "$PLUGIN_MANIFEST"
}

while IFS= read -r requirement || [[ -n "$requirement" ]]; do
    package_name=${requirement%@*}
    plugin_name=${package_name##*/}
    installed_spec=$(
        openclaw plugins inspect "$plugin_name" --json 2>/dev/null |
            jq -r '.install.spec // empty' || true
    )

    if [[ "$installed_spec" == "$requirement" ]]; then
        printf '%s is already pinned\n' "$requirement"
        continue
    fi

    openclaw plugins install "$requirement" --force --pin

    read -r installed_spec resolved_spec < <(
        openclaw plugins inspect "$plugin_name" --json |
            jq -r '[.install.spec, .install.resolvedSpec] | @tsv'
    )
    if [[ "$installed_spec" != "$requirement" ]] || \
        [[ "$resolved_spec" != "$requirement" ]]; then
        printf 'ERROR: plugin pin verification failed: %s\n' "$requirement" >&2
        exit 1
    fi
done < <(read_manifest)