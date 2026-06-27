#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: /opt/openclaw-cli.sh <openclaw-args...>" >&2
  exit 64
fi

if [[ ! -r /etc/openclaw-gateway.env ]]; then
  echo "Missing readable /etc/openclaw-gateway.env" >&2
  exit 1
fi

set -a
source /etc/openclaw-gateway.env
set +a

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  echo "OPENCLAW_GATEWAY_TOKEN is not set in /etc/openclaw-gateway.env" >&2
  exit 1
fi

REMOTE_TOKEN="${OPENCLAW_REMOTE_TOKEN:-$OPENCLAW_GATEWAY_TOKEN}"
exec sudo -u openclaw env OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" OPENCLAW_REMOTE_TOKEN="$REMOTE_TOKEN" openclaw "$@"
