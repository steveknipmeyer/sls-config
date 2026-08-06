#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
APT_MANIFEST="$CONFIG_DIR/packages/apt-required.txt"
PIPX_MANIFEST="$CONFIG_DIR/packages/pipx-tools.txt"
OPENCLAW_PLUGIN_MANIFEST="$CONFIG_DIR/packages/openclaw-plugins.txt"
BOOTSTRAP_SCRIPT="$CONFIG_DIR/scripts/bootstrap-packages.sh"
OPENCLAW_PLUGIN_BOOTSTRAP="$CONFIG_DIR/scripts/bootstrap-openclaw-plugins.sh"
HARVEST_SCRIPT="$CONFIG_DIR/scripts/harvest.sh"
README="$CONFIG_DIR/README.md"
BASHRC_SNAPSHOT="$CONFIG_DIR/state/home/openclaw/.bashrc"
PROFILE_SNAPSHOT="$CONFIG_DIR/state/home/openclaw/.profile"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for path in \
    "$APT_MANIFEST" \
    "$PIPX_MANIFEST" \
    "$OPENCLAW_PLUGIN_MANIFEST" \
    "$BOOTSTRAP_SCRIPT" \
    "$OPENCLAW_PLUGIN_BOOTSTRAP"; do
    [[ -f "$path" ]] || fail "missing ${path#"$CONFIG_DIR/"}"
done

first_harvest_command=$(
    sed '1d' "$HARVEST_SCRIPT" |
        sed -n '/^[[:space:]]*\(#.*\)\?$/!{p;q;}'
)
[[ "$first_harvest_command" == 'set -euo pipefail' ]] || \
    fail "harvest must not execute commands from its documentation header"

grep -Fxq 'pipx' "$APT_MANIFEST" || fail "apt manifest must install pipx"
grep -Fxq 'python3-venv' "$APT_MANIFEST" || \
    fail "apt manifest must install python3-venv"

grep -Fxq 'ruff==0.16.1' "$PIPX_MANIFEST" || fail "Ruff must be pinned"
grep -Fxq 'black==26.5.1' "$PIPX_MANIFEST" || fail "Black must be pinned"

if grep -Ev '^(#.*|[[:space:]]*|[a-z0-9][a-z0-9+.-]*)$' "$APT_MANIFEST"; then
    fail "apt manifest must contain package names without version snapshots"
fi

if grep -Ev '^(#.*|[[:space:]]*|[a-zA-Z0-9_.-]+==[a-zA-Z0-9_.+-]+)$' \
    "$PIPX_MANIFEST"; then
    fail "pipx manifest entries must use exact name==version pins"
fi

grep -Fxq '@openclaw/codex@2026.7.1-1' "$OPENCLAW_PLUGIN_MANIFEST" || \
    fail "Codex plugin must be pinned to the installed compatible version"
if grep -Ev '^(#.*|[[:space:]]*|@[a-z0-9._-]+/[a-z0-9._-]+@[0-9][a-zA-Z0-9._+-]*)$' \
    "$OPENCLAW_PLUGIN_MANIFEST"; then
    fail "OpenClaw plugin manifest entries must use exact scoped npm specs"
fi

grep -Fq '[[ ${EUID} -eq 0 ]]' "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must require root"
grep -Fq 'runuser -u openclaw --' "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must run pipx as openclaw"
grep -Fq 'install -d -o openclaw -g openclaw -m 0755 "$PIPX_HOME" "$PIPX_BIN_DIR"' \
    "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must give openclaw ownership of pipx-managed directories"
grep -Fq '/home/openclaw/.local/bin' "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must verify the openclaw pipx binary directory"
grep -Fq "sed -n 's/^Version: //p' || true" "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must tolerate a missing pipx environment on first run"
grep -Fq 'read -r requirement || [[ -n "$requirement" ]]' "$BOOTSTRAP_SCRIPT" || \
    fail "bootstrap must process an unterminated final pipx manifest entry"
if grep -Fq 'run_pipx ensurepath' "$BOOTSTRAP_SCRIPT"; then
    fail "bootstrap must not let pipx modify shell startup files"
fi
grep -Fq '[[ ${EUID} -ne 0 ]]' "$OPENCLAW_PLUGIN_BOOTSTRAP" || \
    fail "OpenClaw plugin bootstrap must reject root execution"
grep -Fq 'plugins install "$requirement" --force --pin' \
    "$OPENCLAW_PLUGIN_BOOTSTRAP" || \
    fail "OpenClaw plugin bootstrap must persist exact pinned specs"
grep -Fq 'plugins inspect "$plugin_name" --json' \
    "$OPENCLAW_PLUGIN_BOOTSTRAP" || \
    fail "OpenClaw plugin bootstrap must inspect existing records"
grep -Fq 'PATH="$HOME/.local/bin:$PATH"' "$PROFILE_SNAPSHOT" || \
    fail "profile must configure the openclaw user-local binary directory"
if grep -Fq '/home/openclaw/.local/bin' "$BASHRC_SNAPSHOT"; then
    fail "PATH configuration belongs in .profile, not .bashrc"
fi

grep -Fq 'apt-mark showmanual' "$HARVEST_SCRIPT" || \
    fail "harvest must capture manually selected apt packages"
grep -Fq 'dpkg-query -W' "$HARVEST_SCRIPT" || \
    fail "harvest must capture complete dpkg package versions"
grep -Fq 'pipx list --json' "$HARVEST_SCRIPT" || \
    fail "harvest must capture structured pipx state"
grep -Fq '/home/openclaw/.local/bin/ruff --version' "$HARVEST_SCRIPT" || \
    fail "harvest must capture the installed Ruff version"
grep -Fq '/home/openclaw/.local/bin/black --version' "$HARVEST_SCRIPT" || \
    fail "harvest must capture the installed Black version"

for snapshot in apt-manual.txt dpkg-packages.txt pipx-tools.json; do
    grep -Fq "config/state/$snapshot" "$HARVEST_SCRIPT" || \
        fail "harvest expected-file audit must include $snapshot"
done

grep -Fq 'scripts/bootstrap-openclaw-plugins.sh' "$README" || \
    fail "fresh-host documentation must include OpenClaw plugin bootstrap"

printf 'PASS: package bootstrap contract is valid\n'
