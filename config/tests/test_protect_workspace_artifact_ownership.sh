#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROTECT_SCRIPT="$SCRIPT_DIR/../state/opt/protect-workspace.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

grep -q 'chown openclaw:openclaw "$ARTIFACT"' "$PROTECT_SCRIPT" || \
    fail "root-run checks must return the artifact to openclaw ownership"

printf 'PASS: workspace protection artifact ownership\n'