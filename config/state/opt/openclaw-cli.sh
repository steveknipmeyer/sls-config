#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: /opt/openclaw-cli.sh <openclaw-args...>" >&2
  exit 64
fi

if [[ ! -r /opt/openclaw.env ]]; then
  echo "Missing readable /opt/openclaw.env" >&2
  exit 1
fi

set -a
source /opt/openclaw.env
set +a

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  echo "OPENCLAW_GATEWAY_TOKEN is not set in /opt/openclaw.env" >&2
  exit 1
fi

exec sudo -u openclaw env OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" openclaw "$@"
