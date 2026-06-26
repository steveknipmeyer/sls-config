#!/usr/bin/env bash
set -euo pipefail

TARGET="/home/openclaw/.openclaw/skills/openclaw-cli/scripts/openclaw-exec.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "openclaw-exec forwarder target missing or not executable: $TARGET" >&2
  exit 1
fi

exec "$TARGET" "$@"
