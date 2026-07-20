#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HARVEST_SCRIPT="$SCRIPT_DIR/../scripts/harvest.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

grep -q 'plugins inspect codex --json' "$HARVEST_SCRIPT" || \
    fail "harvest must inspect the active Codex plugin"

grep -q '\.plugin\.rootDir // empty' "$HARVEST_SCRIPT" || \
    fail "harvest must resolve the active Codex root structurally"

if grep -q 'append_path_state.*npm/node_modules/@openclaw/codex' "$HARVEST_SCRIPT"; then
    fail "harvest must not report only the retired top-level Codex path"
fi

printf 'PASS: harvest resolves generation-scoped Codex state\n'