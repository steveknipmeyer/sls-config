#!/usr/bin/env bash
# =============================================================================
# harvest.sh — OpenClaw Environment Snapshot Script
# =============================================================================
#
# PURPOSE:
#   Collects configuration files and system state from the sls DigitalOcean
#   Droplet running OpenClaw into a versioned snapshot directory. The goal is
#   to capture everything needed to reproduce this environment on a fresh
#   Ubuntu box.
#
#   Scope boundary (important): this script captures host-side state that is
#   not reliably reconstructed from git alone (for example /opt files, /etc
#   configs, systemd units, root crontab, and redacted runtime config).
#   It is not a substitute for committing source-controlled repo files.
#
#   In this repo, `cron/` is version-controlled except explicitly ignored
#   runtime ledgers (`cron/runs/`) and `cron/jobs-state.json`.
#
#   This script is designed to be run manually or from a cron job. It does
#   NOT commit to git — that is a separate step, allowing you to review
#   changes before committing.
#
# USAGE:
#   Run as root for full access to all root-owned files:
#   sudo bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh
#
#   Then commit as the openclaw user:
#   git -C /home/openclaw/.openclaw/projects/sls-config add config/
#   git -C /home/openclaw/.openclaw/projects/sls-config commit -m "harvest snapshot $(date +%Y-%m-%d)"
#   git -C /home/openclaw/.openclaw/projects/sls-config push
#
# OUTPUT STRUCTURE:
#   projects/sls-config/config/
#     schemas/
#       openclaw.schema.json            — OpenClaw config JSON schema (for VS Code IntelliSense)
#     scripts/
#       harvest.sh                      — this script
#     state/
#       README.md                       — auto-generated index with timestamp + versions
#       opt/
#         openclaw.env                  — REDACTED: secrets replaced with placeholders
#         restart-openclaw.sh           — Service restart helper (DigitalOcean installer)
#         tailscale-reauth.sh           — Tailscale pre-auth key renewal (custom)
#         rotate-openclaw-gateway.sh    — Gateway token rotation (custom, reviewed)
#         status-openclaw.sh            — Service status helper (DigitalOcean installer)
#         update-openclaw.sh            — Update helper (DigitalOcean installer)
#         setup-openclaw-domain.sh      — Caddy domain setup (DigitalOcean installer, DISABLED)
#         openclaw-cli.sh               — CLI launcher helper (DigitalOcean installer)
#         openclaw-tui.sh               — TUI launcher helper (DigitalOcean installer, see WARNING)
#       etc/
#         apparmor.d/
#           openclaw-codex-bwrap       — Local Codex bwrap AppArmor profile (or absence note)
#         sls-web-server.env            — REDACTED: host-side OAuth env for web server
#         ssh/
#           sshd_config                 — SSH server hardening config
#       home/
#         openclaw/
#           .bashrc                     — openclaw user shell environment
#           .ssh/
#             config                    — SSH client config (deploy key stanza etc.)
#           dot-openclaw/
#             openclaw.json             — REDACTED: primary OpenClaw runtime config
#             exec-approvals.json       — REDACTED: local exec approvals policy + socket token
#       usr/
#         local/
#           bin/
#             openclaw                  — root guard stub (blocks openclaw CLI as root)
#       systemd/
#         openclaw.service              — Root-level systemd service definition
#         sls-web-server.service        — Express web server systemd service
#       versions.txt                    — Runtime version snapshot (node, npm, openclaw)
#       docker-images.txt               — Docker images present on the host
#       ufw-status.txt                  — Firewall rules
#       openclaw-doctor.txt             — Output of `openclaw doctor` at harvest time
#       local-workarounds.txt           — Generated report of ignored/local compatibility shims
#
# REDACTION:
#   openclaw.env contains the ANTHROPIC_API_KEY and other secrets.
#   This script redacts known secret patterns before writing to the snapshot.
#   Redacted values are replaced with REDACTED so the key name is preserved
#   for documentation purposes.
#
#   openclaw.json contains gateway and hooks tokens. These are redacted using
#   jq to target the exact JSON paths. The folder is named "dot-openclaw" in
#   the snapshot (not ".openclaw") to prevent it from being caught by the
#   .openclaw entry in .gitignore.
#
#   exec-approvals.json contains the local approvals socket token. This must
#   also be redacted before committing. Only the socket path and approval
#   policy should remain visible in the snapshot.
#
#   IMPORTANT: Always review config/state/ before committing to git.
#   Run: git -C /home/openclaw/.openclaw/projects/sls-config diff config/state/
#   And: grep -r "REDACTED" /home/openclaw/.openclaw/projects/sls-config/config/state/opt/openclaw.env
#   And: grep -r "REDACTED" /home/openclaw/.openclaw/projects/sls-config/config/state/etc/sls-web-server.env
#
# =============================================================================

set -euo pipefail

# This script intentionally harvests root-owned files and system state.
# Fail fast if not run as root so we don't produce a partial, misleading snapshot.
if [[ "$EUID" -ne 0 ]]; then
    echo "[harvest] ERROR: must be run as root." >&2
    echo "[harvest] Run: sudo bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh" >&2
    exit 1
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_ROOT="/home/openclaw/.openclaw/projects/sls-config"
STATE_DIR="${CONFIG_ROOT}/config/state"
SCHEMA_DIR="${CONFIG_ROOT}/config/schemas"
SCRIPT_DIR="${CONFIG_ROOT}/config/scripts"

# Timestamp for this harvest run
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_ONLY=$(date -u +"%Y-%m-%d")

# =============================================================================
# HELPERS
# =============================================================================

log() {
    echo "[harvest] $1"
}

# Log a warning in red. Degrades gracefully to plain text if the terminal
# does not support ANSI color codes.
log_warn() {
    echo -e "\033[0;31m[harvest] $1\033[0m"
}

# Copy a file, using sudo if needed for root-owned files.
# Usage: harvest_file <source_path> <dest_path>
harvest_file() {
    local src="$1"
    local dest="$2"
    local dest_dir
    dest_dir=$(dirname "$dest")

    mkdir -p "$dest_dir"

    if [ -r "$src" ]; then
        # Readable directly (openclaw-owned files)
        cp "$src" "$dest"
        log "  ✓ $src"
    elif sudo -n cat "$src" > /dev/null 2>&1; then
        # Readable via passwordless sudo
        sudo cat "$src" > "$dest"
        log "  ✓ $src (via sudo)"
    else
        log "  ✗ $src (permission denied — skipping)"
        echo "# HARVEST ERROR: Could not read $src" > "$dest"
    fi
}

# Redact known secret patterns in a file (in-place).
# Replaces the VALUE of key=value pairs for known secret keys.
# Preserves the key name so the file remains useful as documentation.
redact_secrets() {
    local file="$1"

    local tmp_file
    tmp_file=$(mktemp)

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            if [[ ! "$key" =~ _URL$ ]] && [[ "$key" =~ (API_KEY|ADMIN_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|CLIENT_ID) ]]; then
                local quote=""

                if [[ ${#value} -ge 2 ]]; then
                    local first_char="${value:0:1}"
                    local last_char="${value: -1}"

                    if [[ "$first_char" == '"' && "$last_char" == '"' ]]; then
                        quote='"'
                    elif [[ "$first_char" == "'" && "$last_char" == "'" ]]; then
                        quote="'"
                    fi
                fi

                printf '%s=%sREDACTED%s\n' "$key" "$quote" "$quote" >> "$tmp_file"
                continue
            fi
        fi

        printf '%s\n' "$line" >> "$tmp_file"
    done < "$file"

    mv "$tmp_file" "$file"

    # Tailscale pre-auth keys: --authkey=tskey-auth-... (lowercase, flag-style)
    sed -i -E "s|(--authkey=)[^ ]+|\1REDACTED|g" "$file"

    log "  → Redacted secrets in $(basename "$file")"
}

# Run a command and save output to a file, with error handling.
# Usage: capture_command <dest_file> <command...>
capture_command() {
    local dest="$1"
    shift
    local dest_dir
    dest_dir=$(dirname "$dest")
    mkdir -p "$dest_dir"

    if "$@" > "$dest" 2>&1; then
        log "  ✓ $* → $(basename "$dest")"
    else
        log "  ✗ $* failed (output saved anyway)"
    fi
}

# Describe the current state of a path in a generated text report.
# Usage: append_path_state <dest_file> <path>
append_path_state() {
    local dest="$1"
    local target_path="$2"

    if [ -L "$target_path" ]; then
        local link_target
        local resolved_target
        link_target=$(readlink "$target_path")
        resolved_target=$(readlink -f "$target_path" 2>/dev/null || true)
        printf -- "- %s: symlink -> %s\n" "$target_path" "$link_target" >> "$dest"
        if [ -n "$resolved_target" ]; then
            printf "  resolved: %s\n" "$resolved_target" >> "$dest"
        fi
    elif [ -f "$target_path" ]; then
        printf -- "- %s: file present\n" "$target_path" >> "$dest"
    elif [ -d "$target_path" ]; then
        printf -- "- %s: directory present\n" "$target_path" >> "$dest"
    else
        printf -- "- %s: absent\n" "$target_path" >> "$dest"
    fi
}

# Run OpenClaw CLI as the openclaw user even when harvest itself runs as root.
# This preserves the root-guard contract and avoids accidental root-scoped CLI side effects.
run_openclaw_as_openclaw() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u openclaw -- /usr/bin/openclaw "$@"
        return
    fi

    if command -v su >/dev/null 2>&1; then
        local escaped_args
        printf -v escaped_args '%q ' "$@"
        su - openclaw -c "/usr/bin/openclaw ${escaped_args% }"
        return
    fi

    log "  ✗ missing runuser/su; cannot run openclaw as openclaw user"
    return 127
}

# =============================================================================
# MAIN
# =============================================================================

log "Starting harvest at ${TIMESTAMP}"
log "Config root:      ${CONFIG_ROOT}"
log "State directory:  ${STATE_DIR}"
log "Schema directory: ${SCHEMA_DIR}"

# Create directory structure
mkdir -p \
    "${SCHEMA_DIR}" \
    "${STATE_DIR}/opt" \
    "${STATE_DIR}/etc/apparmor.d" \
    "${STATE_DIR}/etc/ssh" \
    "${STATE_DIR}/home/openclaw/.ssh" \
    "${STATE_DIR}/home/openclaw/dot-openclaw" \
    "${STATE_DIR}/systemd" \
    "${STATE_DIR}/crontabs" \
    "${STATE_DIR}/usr/local/bin"

# =============================================================================
# SECTION 1: /opt files
#
# The DigitalOcean 1-click installer places operational scripts in /opt.
# These are all root-owned. Some were installed by DigitalOcean, some were
# created or modified during our setup. All are documented below.
# =============================================================================

log ""
log "=== /opt files ==="

# ---
# openclaw.env — the primary runtime environment file.
# Loaded by /etc/systemd/system/openclaw.service via EnvironmentFile=.
# Contains ANTHROPIC_API_KEY and OPENCLAW_GATEWAY_TOKEN.
# MUST be redacted before committing — redaction runs automatically below.
# Origin: DigitalOcean installer (created Mar 20), modified during setup (Mar 29).
# ---
harvest_file "/opt/openclaw.env" "${STATE_DIR}/opt/openclaw.env"
redact_secrets "${STATE_DIR}/opt/openclaw.env"

# ---
# sls-billing-reader.json — Google Cloud service account key for the sls-costs
# billing reader. Grants billing.viewer access to billing account 01330B-687892-E43BAA
# so the sls-costs root fetch script can query Gemini API spend via the Cloud Billing API.
# The private_key field is a multi-line RSA key — redacted via jq.
# Reference: projects/sls-dev/docs/architecture/sls-costs.md, Credential Setup Guide
# Created: 2026-05-23.
# ---
if [ -f "/opt/sls-billing-reader.json" ]; then
    harvest_file "/opt/sls-billing-reader.json" "${STATE_DIR}/opt/sls-billing-reader.json"
    jq '.private_key = "REDACTED" | .private_key_id = "REDACTED"' \
        "${STATE_DIR}/opt/sls-billing-reader.json" > /tmp/sls-billing-reader.json.redacted \
    && mv /tmp/sls-billing-reader.json.redacted "${STATE_DIR}/opt/sls-billing-reader.json"
    log "  → Redacted private_key + private_key_id in sls-billing-reader.json (jq)"
else
    log "  ✗ /opt/sls-billing-reader.json absent — skipping"
fi

# ---
# restart-openclaw.sh — helper to restart the OpenClaw service.
# Runs: systemctl restart openclaw
# References the ROOT-LEVEL service (/etc/systemd/system/openclaw.service).
#
# WARNING: Do NOT run `openclaw gateway install` on this VPS deployment.
# That command creates a USER-LEVEL service (~/.config/systemd/user/openclaw-gateway.service)
# which conflicts with the root-level service, causes duplicate gateway processes,
# and fails to load /opt/openclaw.env (breaking the Anthropic API key).
# The user-level service is only appropriate for desktop/laptop deployments.
#
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/restart-openclaw.sh" "${STATE_DIR}/opt/restart-openclaw.sh"

# ---
# tailscale-reauth.sh — renews the Tailscale pre-auth key.
# Must be run every 90 days to keep the Droplet authenticated to the tailnet.
# Origin: Created during setup (Mar 29).
# ---
harvest_file "/opt/tailscale-reauth.sh" "${STATE_DIR}/opt/tailscale-reauth.sh"
redact_secrets "${STATE_DIR}/opt/tailscale-reauth.sh"

# ---
# rotate-openclaw-gateway.sh — rotates the OpenClaw gateway auth token.
# REVIEWED AND CORRECTED: The original script (generated Mar 29) incorrectly
# attempted to copy /root/.openclaw/openclaw.json to /home/openclaw/.openclaw/openclaw.json.
# These are the same file via symlink — the copy was unnecessary and has been removed.
# As of 2026-05-13, the script should follow the config-first policy documented
# in extras/MAINTENANCE.md: do not keep OPENCLAW_GATEWAY_TOKEN in /opt/openclaw.env.
# Origin: Created during setup (Mar 29), reviewed and corrected.
# ---
harvest_file "/opt/rotate-openclaw-gateway.sh" "${STATE_DIR}/opt/rotate-openclaw-gateway.sh"
redact_secrets "${STATE_DIR}/opt/rotate-openclaw-gateway.sh"

# ---
# status-openclaw.sh — shows service status and gateway token.
# WARNING: This script prints the raw gateway token to stdout.
# Do not run in shared terminal sessions or pipe output to logs.
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/status-openclaw.sh" "${STATE_DIR}/opt/status-openclaw.sh"

# ---
# complete-openclaw-upgrade.sh — full OpenClaw upgrade automation.
# Covers backup, install, axios integrity check, doctor, plugin reconciliation,
# env update, gateway restart, and version verification.
# Replaces update-openclaw.sh. Harvest/commit left as a manual step.
# Origin: SLS session 54 (May 26 2026).
# ---
harvest_file "/opt/complete-openclaw-upgrade.sh" "${STATE_DIR}/opt/complete-openclaw-upgrade.sh"

# ---
# update-openclaw.sh — DEPRECATED. Moved to /opt/deprecated/.
# Replaced by complete-openclaw-upgrade.sh. Original used npm update -g which
# does not reliably install the latest version and skips security checks.
# Origin: DigitalOcean installer (Mar 20). Now a blocking wrapper.
# ---
harvest_file "/opt/deprecated/update-openclaw.sh" "${STATE_DIR}/opt/deprecated/update-openclaw.sh"

# ---
# setup-openclaw-domain.sh — DEPRECATED. Moved to /opt/deprecated/.
# Configures Caddy as a public HTTPS reverse proxy — incompatible with the
# current Tailscale-only architecture (zero public ports, no Caddy).
# Origin: DigitalOcean installer (Mar 20).
# ---
harvest_file "/opt/deprecated/setup-openclaw-domain.sh" "${STATE_DIR}/opt/deprecated/setup-openclaw-domain.sh"

# ---
# openclaw-cli.sh — helper to run OpenClaw CLI commands as the openclaw user.
# Runs: su - openclaw -c "openclaw $*"
# Useful when running CLI commands as root and needing to switch to openclaw user.
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/openclaw-cli.sh" "${STATE_DIR}/opt/openclaw-cli.sh"

# ---
# openclaw-tui.sh — launches the OpenClaw TUI as the openclaw user.
# Simplified in session 54: no longer reads openclaw.json or passes --token
# (the TUI authenticates automatically via local gateway connection).
# Just delegates: su - openclaw -c "openclaw tui $*"
# Origin: DigitalOcean installer (Mar 20), updated session 54.
# ---
harvest_file "/opt/openclaw-tui.sh" "${STATE_DIR}/opt/openclaw-tui.sh"

# =============================================================================
# SECTION 2: /etc/ssh
#
# SSH server configuration. This was hardened during initial setup:
# - Root SSH login disabled
# - Only gradient and openclaw users permitted
# - Key-only authentication (no passwords)
# =============================================================================

log ""
log "=== /etc/ssh ==="

harvest_file "/etc/ssh/sshd_config" "${STATE_DIR}/etc/ssh/sshd_config"

# =============================================================================
# SECTION 2a: AppArmor compatibility profile
#
# Local host workaround for Codex bwrap on Ubuntu/AppArmor systems.
# This file is optional on hosts where the workaround is no longer needed, but
# the snapshot always records whether it was present at harvest time.
# =============================================================================

log ""
log "=== /etc/apparmor.d ==="

if [ -f "/etc/apparmor.d/openclaw-codex-bwrap" ]; then
    harvest_file "/etc/apparmor.d/openclaw-codex-bwrap" "${STATE_DIR}/etc/apparmor.d/openclaw-codex-bwrap"
else
    cat > "${STATE_DIR}/etc/apparmor.d/openclaw-codex-bwrap" << 'EOF'
# openclaw-codex-bwrap was not present on this host at harvest time.
# If Codex bwrap compatibility still depends on a local AppArmor profile,
# recreate /etc/apparmor.d/openclaw-codex-bwrap before relying on sandboxed
# workspace-write sessions.
EOF
    log "  ✓ /etc/apparmor.d/openclaw-codex-bwrap (absence noted)"
fi

# =============================================================================
# SECTION 2b: Root crontab
#
# Root's crontab contains the sls-system audit script entries. These scripts
# require root to read /var/log/auth.log, query fail2ban-client, and get full
# process/port visibility. They run at 3:40 AM ET, writing JSON output to
# Ada's working directory for the 3:45 AM sls-system OpenClaw cron to read.
#
# The LLM (Ada's sls-system skill) never executes privileged commands —
# it only reads the pre-generated JSON files.
# =============================================================================

log ""
log "=== Root crontab ==="

if crontab -u root -l > "${STATE_DIR}/crontabs/root" 2>/dev/null; then
    log "  ✓ root crontab"
else
    log "  ✗ root crontab (empty or inaccessible)"
    echo "# root crontab: empty or could not be read at harvest time" > "${STATE_DIR}/crontabs/root"
fi

# =============================================================================
# SECTION 3: openclaw user home files
#
# User-level configuration for the openclaw account.
# =============================================================================

log ""
log "=== /home/openclaw ==="

# .profile — login shell environment for the openclaw user.
# Contains: umask 022 fix (overrides PAM's private-group 002 default),
# PATH entry for ~/.npm-global/bin (Claude Code CLI), NODE_COMPILE_CACHE,
# and OPENCLAW_NO_RESPAWN. Must be in .profile (not .bashrc) so these
# survive runuser -l and other non-interactive login shells used by cron.
harvest_file "/home/openclaw/.profile" "${STATE_DIR}/home/openclaw/.profile"

# .bashrc — interactive shell environment for the openclaw user.
harvest_file "/home/openclaw/.bashrc" "${STATE_DIR}/home/openclaw/.bashrc"

# .npmrc — npm configuration for the openclaw user.
# Sets prefix=/home/openclaw/.openclaw/workspace/npm so all global npm
# installs go to the OpenClaw-managed prefix, not ~/.npm-global.
harvest_file "/home/openclaw/.npmrc" "${STATE_DIR}/home/openclaw/.npmrc"

# .gitconfig — git identity for the openclaw user.
# Sets Ada's commit author name, email, and default branch.
harvest_file "/home/openclaw/.gitconfig" "${STATE_DIR}/home/openclaw/.gitconfig"

# .ssh/config — SSH client configuration.
# Contains the deploy key stanza for github.com (id_ed25519_sls)
# which allows git push to the ada repo without agent forwarding.
# This enables both manual commits (from VS Code/terminal) and automated commits
# (from Ada via cron) to use the same deploy key.
# NOTE: Private keys are NOT harvested — only the config file.
harvest_file "/home/openclaw/.ssh/config" "${STATE_DIR}/home/openclaw/.ssh/config"

# openclaw.code-workspace — VS Code workspace configuration for sls.
# Controls: folder roots, JSON schema bindings (openclaw.json + skill configs),
# files.watcherExclude/files.exclude/search.exclude to prevent indexing of
# large or irrelevant directories (homebrew, workspace/npm, projects/openclaw).
# Not a secret — no redaction needed.
harvest_file "/home/openclaw/.openclaw/openclaw.code-workspace" "${STATE_DIR}/home/openclaw/openclaw.code-workspace"

# openclaw.json — the primary OpenClaw runtime configuration file.
# This is the most important configuration file — it controls:
#   - Sandbox mode and Docker image selection
#   - Primary model (claude-sonnet-4-6)
#   - Heartbeat settings (interval, model, isolatedSession, lightContext)
#   - Memory search settings
#   - Gateway configuration (mode, Tailscale, allowed origins)
#   - Tool execution settings (exec host, security, ask)
#   - Command settings
#
# NOTE ON SYMLINK: /root/.openclaw/openclaw.json and
# /home/openclaw/.openclaw/openclaw.json are the SAME FILE via symlink.
# We harvest from the openclaw user path as the canonical location.
#
# NOTE ON FOLDER NAME: The destination folder is named "dot-openclaw" (not
# ".openclaw") to prevent it from being caught by the .openclaw entry in
# .gitignore. The .gitignore protects live runtime state; "dot-openclaw" is
# a safe, intentionally-committed redacted snapshot.
#
# MUST be redacted — contains gateway.auth.token, gateway.remote.token,
# and hooks.token. On sls, openclaw.json is the canonical gateway auth source.
# Redaction uses jq to target exact JSON paths.
harvest_file "/home/openclaw/.openclaw/openclaw.json" "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
jq '
    .gateway.auth.token = "REDACTED" |
    .gateway.remote.token = "REDACTED" |
    .hooks.token = "REDACTED" |
    if .skills.entries then
        .skills.entries |= with_entries(
            if .value.env then
                .value.env |= with_entries(.value = "REDACTED")
            else . end
        )
    else . end |
    if .agents.defaults.sandbox.docker.env then
        .agents.defaults.sandbox.docker.env |= with_entries(.value = "REDACTED")
    else . end |
    if .agents.list then
        .agents.list |= map(
            if .sandbox.docker.env then
                .sandbox.docker.env |= with_entries(.value = "REDACTED")
            else . end
        )
    else . end
' "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json" > /tmp/openclaw.json.redacted \
&& mv /tmp/openclaw.json.redacted "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
log "  → Redacted secrets in openclaw.json (jq)"

# exec-approvals.json — local host exec-approval policy.
# Captures the host-local approvals layer that combines with tools.exec.* in
# openclaw.json. This is part of the effective security posture and must be
# reconstructable alongside the main runtime config.
#
# MUST be redacted — contains the local approvals socket token. Redaction uses
# jq to replace only .socket.token, preserving the policy structure.
harvest_file "/home/openclaw/.openclaw/exec-approvals.json" "${STATE_DIR}/home/openclaw/dot-openclaw/exec-approvals.json"
jq '
    .socket.token = "REDACTED"
' "${STATE_DIR}/home/openclaw/dot-openclaw/exec-approvals.json" > /tmp/exec-approvals.json.redacted \
&& mv /tmp/exec-approvals.json.redacted "${STATE_DIR}/home/openclaw/dot-openclaw/exec-approvals.json"
log "  → Redacted secrets in exec-approvals.json (jq)"

# openclaw root guard stub — prevents accidental openclaw CLI usage as root.
# Installed at /usr/local/bin/openclaw, intercepts openclaw commands run as
# root and redirects to: sudo -u openclaw openclaw <command>.
# See MAINTENANCE.md for full explanation of the two-config problem.
harvest_file "/usr/local/bin/openclaw" "${STATE_DIR}/usr/local/bin/openclaw"

# =============================================================================
# SECTION 3c: OpenClaw config schema
#
# The JSON schema for openclaw.json, generated from the installed binary.
# Stored in extras/config/schemas/ and connected to openclaw.json via the
# VS Code workspace file (openclaw.code-workspace) for IntelliSense editing.
#
# The schema evolves with each OpenClaw version — capturing it alongside the
# state snapshot allows correlation between config structure and version.
#
# NOTE: Schema generation should be read-only, but this script still runs the
# OpenClaw CLI as the openclaw user to keep behavior aligned with the root
# guard contract and avoid relying on root-side CLI assumptions.
# =============================================================================

log ""
log "=== OpenClaw config schema ==="

if run_openclaw_as_openclaw config schema > "${SCHEMA_DIR}/openclaw.schema.json" 2>/dev/null; then
    log "  ✓ openclaw.schema.json"
else
    log "  ✗ openclaw config schema failed — schema not captured"
fi

# =============================================================================
# SECTION 4: systemd service
#
# The root-level systemd service that runs the OpenClaw gateway.
# This is the CORRECT service for a VPS deployment.
#
# Key properties:
# - Installed at /etc/systemd/system/openclaw.service
# - Runs as User=openclaw (not root)
# - Loads /opt/openclaw.env via EnvironmentFile
# - Requires docker.service (sandbox dependency)
# - WantedBy=multi-user.target (starts on boot without user login)
#
# Do NOT run `openclaw gateway install` — it creates a conflicting user-level
# service. See restart-openclaw.sh comment above for full explanation.
# =============================================================================

log ""
log "=== systemd ==="

harvest_file "/etc/systemd/system/openclaw.service" "${STATE_DIR}/systemd/openclaw.service"

# sls-web-server.service — Express web server serving agent-generated content
# via Tailscale at https://sls.tail1cd974.ts.net:3001
# Runs as openclaw user, binds to 127.0.0.1:3001 (loopback only — see MAINTENANCE.md
# for important note about Tailscale/Express port contention on port 3001).
harvest_file "/etc/systemd/system/sls-web-server.service" "${STATE_DIR}/systemd/sls-web-server.service"

# sls-web-server.env — dedicated host-side environment for the Express web server.
# Used for OAuth callback configuration and static client credentials that should
# not be injected into every sandbox session.
harvest_file "/etc/sls-web-server.env" "${STATE_DIR}/etc/sls-web-server.env"
redact_secrets "${STATE_DIR}/etc/sls-web-server.env"

# =============================================================================
# SECTION 5: Runtime version snapshot
#
# Captures exact versions of all runtime components. Essential for
# reproducing the environment — version mismatches are a common source of
# failures when rebuilding.
# =============================================================================

log ""
log "=== Version snapshot ==="

{
    echo "# OpenClaw Environment — Version Snapshot"
    echo "# Generated: ${TIMESTAMP}"
    echo ""
    echo "## OpenClaw"
    run_openclaw_as_openclaw --version 2>/dev/null || echo "openclaw: not found"
    echo ""
    echo "## Node.js"
    node --version 2>/dev/null || echo "node: not found"
    echo ""
    echo "## npm"
    npm --version 2>/dev/null || echo "npm: not found"
    echo ""
    echo "## Operating System"
    uname -a 2>/dev/null || echo "uname: not available"
    lsb_release -a 2>/dev/null || echo "lsb_release: not available"
    echo ""
    echo "## Docker"
    docker --version 2>/dev/null || echo "docker: not found"
    echo ""
    echo "## Tailscale"
    tailscale version 2>/dev/null || echo "tailscale: not found"
} > "${STATE_DIR}/versions.txt"
log "  ✓ versions.txt"

# =============================================================================
# SECTION 6: Docker images
#
# Lists all Docker images on the host. The sandbox images are built locally
# (not pulled from a registry) and must be rebuilt on a new host using:
#   scripts/sandbox-setup.sh        → openclaw-sandbox:bookworm-slim (base)
#   scripts/sandbox-common-setup.sh → openclaw-sandbox-common:bookworm-slim (required)
#
# The common image is what Ada actually uses — it includes python3, git,
# nodejs, and other tools required for sandbox filesystem operations.
# The slim image alone is NOT sufficient — it lacks python3.
# =============================================================================

log ""
log "=== Docker images ==="

capture_command "${STATE_DIR}/docker-images.txt" docker images

# =============================================================================
# SECTION 7: Firewall rules
#
# UFW firewall status. On this deployment, all public ports are blocked:
# - DigitalOcean cloud firewall (sls-firewall): no inbound rules
# - UFW: SSH restricted to Tailscale interface only
# - Caddy (ports 80/443) has been disabled
# OpenClaw is accessed exclusively via Tailscale (zero public attack surface).
# =============================================================================

log ""
log "=== Firewall ==="

capture_command "${STATE_DIR}/ufw-status.txt" ufw status verbose 2>/dev/null || \
    echo "ufw not available or requires root" > "${STATE_DIR}/ufw-status.txt"

# =============================================================================
# SECTION 8: OpenClaw doctor output
#
# Snapshot of `openclaw doctor` at harvest time. Useful for tracking the
# health of the installation across versions and identifying configuration
# drift over time.
# =============================================================================

log ""
log "=== OpenClaw doctor ==="

# Run with explicit non-interactive flags so doctor cannot block waiting for
# prompt input when stdout is redirected to a file by capture_command.
capture_command "${STATE_DIR}/openclaw-doctor.txt" \
    run_openclaw_as_openclaw doctor --fix --non-interactive --yes

# =============================================================================
# SECTION 8a: Local workaround state
#
# Captures compatibility shims that are easy to miss during reconstruction
# because they live in ignored runtime trees or are generated by repair tools.
# =============================================================================

log ""
log "=== Local workaround state ==="

cat > "${STATE_DIR}/local-workarounds.txt" << EOF
# Local workaround state
# Generated: ${TIMESTAMP}
#
# This report records compatibility shims that are not fully preserved by the
# normal git-tracked repos. Host files should still be harvested separately
# when they are part of reconstruction-critical state.

## Host compatibility shims
EOF

append_path_state "${STATE_DIR}/local-workarounds.txt" "/etc/apparmor.d/openclaw-codex-bwrap"

cat >> "${STATE_DIR}/local-workarounds.txt" << 'EOF'

## Ignored runtime-tree artifacts
EOF

append_path_state "${STATE_DIR}/local-workarounds.txt" "/home/openclaw/.openclaw/npm/node_modules/@openclaw/codex/node_modules/openclaw"

legacy_shim_found=0
for shim_path in /home/openclaw/.openclaw/workspace/skills/sls-*/SKILL.md; do
    if [ -e "$shim_path" ]; then
        legacy_shim_found=1
        append_path_state "${STATE_DIR}/local-workarounds.txt" "$shim_path"
    fi
done

if [ "$legacy_shim_found" -eq 0 ]; then
    printf -- "- /home/openclaw/.openclaw/workspace/skills/sls-*/SKILL.md: absent\n" >> "${STATE_DIR}/local-workarounds.txt"
fi

cat >> "${STATE_DIR}/local-workarounds.txt" << 'EOF'

## Ignore boundaries
- Root repo ignores: npm/
- Workspace repo ignores: /skills/
EOF

log "  ✓ local-workarounds.txt"

# =============================================================================
# SECTION 9: Generate README.md
#
# Auto-generated index for this snapshot. Describes the contents and
# provides context for someone reproducing the environment.
# =============================================================================

log ""
log "=== Generating README.md ==="

OPENCLAW_VERSION=$(run_openclaw_as_openclaw --version 2>/dev/null | grep -oP '\d{4}\.\d+\.\d+' || echo "unknown")

cat > "${STATE_DIR}/README.md" << EOF
# OpenClaw Environment Snapshot

**Generated:** ${TIMESTAMP}
**OpenClaw Version:** ${OPENCLAW_VERSION}
**Host:** sls (DigitalOcean Droplet, NYC1, 2vCPU/4GB)
**Tailscale URL:** https://sls.tail1cd974.ts.net
**Access:** Tailscale-only (zero public ports)

## Purpose

This snapshot captures the configuration needed to reproduce the OpenClaw
environment on a fresh Ubuntu box. It is generated by
\`config/scripts/harvest.sh\` and should be committed to git after review.

## Contents

| File | Origin | Description |
|------|--------|-------------|
| \`state/opt/openclaw.env\` | DO installer + modified | Runtime environment (REDACTED secrets) |
| \`state/opt/restart-openclaw.sh\` | DO installer | Service restart helper |
| \`state/opt/tailscale-reauth.sh\` | Custom | Tailscale key renewal script |
| \`state/opt/rotate-openclaw-gateway.sh\` | Custom (reviewed) | Gateway token rotation |
| \`state/opt/status-openclaw.sh\` | DO installer | Service status helper (WARNING: shows token) |
| \`state/opt/update-openclaw.sh\` | DO installer | Update helper (see NOTE on update procedure) |
| \`state/opt/setup-openclaw-domain.sh\` | DO installer | Caddy setup (DISABLED — do not run) |
| \`state/opt/openclaw-cli.sh\` | DO installer | CLI launcher helper |
| \`state/opt/openclaw-tui.sh\` | DO installer | TUI launcher (WARNING: exposes token in ps aux) |
| \`state/etc/apparmor.d/openclaw-codex-bwrap\` | Local workaround or absence note | Codex bwrap AppArmor profile snapshot |
| \`state/etc/sls-web-server.env\` | Custom | Host-side web server OAuth env (REDACTED secrets) |
| \`state/etc/ssh/sshd_config\` | Custom | Hardened SSH server config |
| \`state/crontabs/root\` | Custom | Root crontab — runs sls-system audit scripts at 3:40 AM ET |
| \`state/home/openclaw/.profile\` | Custom | Login shell env: umask 022, PATH (~/.npm-global/bin), NODE_COMPILE_CACHE, OPENCLAW_NO_RESPAWN |
| \`state/home/openclaw/.bashrc\` | Custom | Interactive shell environment |
| \`state/home/openclaw/.npmrc\` | Custom | npm prefix (workspace/npm) |
| \`state/home/openclaw/.gitconfig\` | Custom | Git identity (Ada's name, email, defaultBranch) |
| \`state/home/openclaw/.ssh/config\` | Custom | SSH client config (deploy key stanza) |
| \`state/home/openclaw/dot-openclaw/openclaw.json\` | Custom | Primary OpenClaw runtime config (REDACTED secrets) |
| \`state/home/openclaw/dot-openclaw/exec-approvals.json\` | Custom | Host-local exec approvals policy (REDACTED socket token) |
| \`state/opt/sls-billing-reader.json\` | Custom | Google Cloud service account key for sls-costs billing reader (REDACTED private_key) |
| \`state/usr/local/bin/openclaw\` | Custom | Root guard stub — blocks openclaw CLI as root |
| \`state/systemd/openclaw.service\` | DO installer | Root-level systemd service definition |
| \`state/systemd/sls-web-server.service\` | Custom | Express web server systemd service |
| \`state/versions.txt\` | Generated | Runtime version snapshot |
| \`state/docker-images.txt\` | Generated | Docker images present on host |
| \`state/ufw-status.txt\` | Generated | Firewall rules |
| \`state/openclaw-doctor.txt\` | Generated | openclaw doctor output at harvest time |
| \`state/local-workarounds.txt\` | Generated | Compatibility shim inventory for ignored/runtime artifacts |
| \`schemas/openclaw.schema.json\` | Generated | OpenClaw config JSON schema (for VS Code IntelliSense) |

## Reproduction Notes

### Service Architecture
OpenClaw runs as a **root-level systemd service** (\`/etc/systemd/system/openclaw.service\`),
NOT as a user-level service. This is critical for VPS deployments.

**WARNING: Do NOT run \`openclaw gateway install\`** on this VPS. That command creates
a user-level service (\`~/.config/systemd/user/openclaw-gateway.service\`) which conflicts
with the root-level service, causes duplicate gateway processes, and fails to load
\`/opt/openclaw.env\` (breaking the Anthropic API key). The user-level service is only
appropriate for desktop/laptop deployments.

### Sandbox Images
The Docker sandbox images are built locally and must be rebuilt on a new host:
\`\`\`bash
cd /path/to/openclaw-source
bash scripts/sandbox-setup.sh                          # builds openclaw-sandbox:bookworm-slim
DOCKER_BUILDKIT=1 bash scripts/sandbox-common-setup.sh # builds openclaw-sandbox-common:bookworm-slim
\`\`\`
The **common image is required** — the slim image alone lacks python3 and cannot
handle sandbox filesystem operations.

### Docker Buildx Plugin
The \`sandbox-common-setup.sh\` script requires Docker BuildKit. Install the
buildx plugin before running it:
\`\`\`bash
# Add the official Docker apt repository first
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-buildx-plugin

# Then build with BuildKit enabled
DOCKER_BUILDKIT=1 bash scripts/sandbox-common-setup.sh
\`\`\`

### OpenClaw Source Repository
The OpenClaw source is cloned at \`/home/openclaw/extras/openclaw\` and is used
to rebuild sandbox Docker images. On a fresh deployment:
\`\`\`bash
mkdir -p /home/openclaw/extras
git clone --depth=1 https://github.com/openclaw/openclaw.git /home/openclaw/extras/openclaw
chown -R openclaw:openclaw /home/openclaw/extras
\`\`\`

### SSH Key Setup (sls machine key)
The openclaw user accesses GitHub via a machine-level SSH key (\`id_ed25519_sls\`)
registered as an account SSH key on GitHub (not a repo-level deploy key).
This gives sls access to all repos the account can access.
On a fresh deployment:
\`\`\`bash
# 1. Generate the machine key on sls as the openclaw user
ssh-keygen -t ed25519 -C "sls-machine" -f /home/openclaw/.ssh/id_ed25519_sls -N ""

# 2. Display the public key
cat /home/openclaw/.ssh/id_ed25519_sls.pub

# 3. Add the public key to GitHub account (NOT repo deploy keys):
#    https://github.com/settings/keys
#    Click "New SSH key"
#    Title: sls-machine
#    Key type: Authentication key
#    Paste the public key

# 4. Add SSH config stanza (already in harvested .ssh/config):
#    Host github.com
#        IdentityFile ~/.ssh/id_ed25519_sls
#        IdentitiesOnly yes

# 5. Test
ssh -T git@github.com
# Expected: Hi steveknipmeyer! You've successfully authenticated...
\`\`\`

### Root Crontab (sls-system audit scripts)

The sls-system audit scripts require root to read \`/var/log/auth.log\`, query
\`fail2ban-client\`, and obtain full process/port visibility. They run via root
cron at 3:40 AM ET — 5 minutes before Ada's sls-system OpenClaw cron at 3:45 AM.
Ada's cron only reads the pre-generated JSON; it performs no privileged execution.

Restore from the harvested crontab:
\`\`\`bash
crontab -u root state/crontabs/root
\`\`\`

Or add the entries manually:
\`\`\`bash
sudo crontab -e
\`\`\`

Expected entries:
\`\`\`
# sls-system: run audit scripts as root, write JSON for Ada's 3:45 AM cron
40 3 * * * mkdir -p /home/openclaw/.openclaw/workspace/working/sls-system && bash /home/openclaw/.openclaw/workspace/.agents/skills/sls-system/scripts/security-audit.sh > /home/openclaw/.openclaw/workspace/working/sls-system/security.json 2>&1 && bash /home/openclaw/.openclaw/workspace/.agents/skills/sls-system/scripts/system-health.sh > /home/openclaw/.openclaw/workspace/working/sls-system/health.json 2>&1
\`\`\`

### Caddy (Disabled)
The DigitalOcean installer included Caddy as a public HTTPS reverse proxy.
It has been disabled since this deployment uses Tailscale exclusively:
\`\`\`bash
sudo systemctl stop caddy
sudo systemctl disable caddy
\`\`\`
Do NOT run \`/opt/setup-openclaw-domain.sh\` — it would re-enable Caddy.

### Update Procedure
The DigitalOcean \`/opt/update-openclaw.sh\` uses \`npm update -g\` which
may not install the latest version. Use instead:
\`\`\`bash
sudo npm install -g openclaw@latest
\`\`\`
See \`extras/MAINTENANCE.md\` for the full recommended update procedure.

### Local Compatibility Workarounds
\`state/etc/apparmor.d/openclaw-codex-bwrap\` captures the host AppArmor
compatibility profile when present and records an absence note otherwise.

\`state/local-workarounds.txt\` records compatibility artifacts that live in
ignored runtime trees, including the nested Codex peer symlink under \`npm/\`
and any legacy \`workspace/skills/sls-*/SKILL.md\` shim files present at
harvest time.

### Secrets
The following secrets are NOT included in this snapshot and must be configured manually:
- \`ANTHROPIC_API_KEY\` — set in \`/opt/openclaw.env\`
- Gateway \`auth.token\` — set in \`~/.openclaw/openclaw.json\`
- Gateway \`remote.token\` — set in \`~/.openclaw/openclaw.json\`
- \`OPENCLAW_SERVICE_KIND=gateway\` — set in \`/opt/openclaw.env\` (not a secret, but required for consistent local gateway auth precedence)
- Webhook hooks \`token\` — only if hooks are re-enabled later. When used, set in \`~/.openclaw/openclaw.json\` and \`/opt/openclaw.env\` as \`OPENCLAW_HOOKS_TOKEN\`. Must be different from the gateway auth token.
- \`~/.openclaw/gateway-token.txt\` — optional legacy convenience file, if you intentionally keep it
- Tailscale pre-auth key — used in \`/opt/tailscale-reauth.sh\`
- SSH private keys — must be generated fresh for each deployment

### Key Configuration Decisions
- \`workspaceAccess: "rw"\` — allows Ada to write memory and workspace files from sandbox
- \`sandbox.docker.image: "openclaw-sandbox-common:bookworm-slim"\` — full-featured sandbox
- \`heartbeat.isolatedSession: true\` — reduces heartbeat token cost
- \`heartbeat.lightContext: true\` — keeps heartbeat context minimal
- \`memorySearch.enabled: false\` — disabled until an embedding provider is configured

### DigitalOcean Cloud Firewall
The \`sls-firewall\` firewall is configured in the DigitalOcean console and is NOT
captured in this snapshot. It is a critical part of the security posture.

Current configuration:
- **Inbound rules:** NONE — all inbound public traffic is blocked at the network level
- **Outbound rules:** All TCP, All UDP, ICMP allowed (standard outbound)
- **Applied to:** sls Droplet

To reproduce on a new Droplet:
1. Go to DigitalOcean console → Networking → Firewalls
2. Create a new firewall with no inbound rules
3. Apply it to the new Droplet

This firewall works in conjunction with UFW (which restricts SSH to Tailscale only)
to provide defense in depth — no public ports are reachable even if UFW is misconfigured.

### Tailscale Setup
Tailscale configuration is NOT fully captured in this snapshot. The reauth script
captures the renewal mechanism but not the initial setup.

To reproduce on a new Droplet:
\`\`\`bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate with a pre-auth key from https://login.tailscale.com/admin/settings/keys
tailscale up --authkey=<pre-auth-key> --hostname=sls

# Enable Tailscale Serve (exposes the gateway on the tailnet via HTTPS)
# OpenClaw handles this automatically when gateway.tailscale.mode="serve" is set in openclaw.json
\`\`\`

The tailnet name is \`tail1cd974.ts.net\` and the Tailscale URL is
\`https://sls.tail1cd974.ts.net\`. The hostname \`sls\` must match for the
URL to resolve correctly.

### gradient User Setup
The \`gradient\` user is the sudo-capable admin account and is NOT captured in
this snapshot. It is required for system administration tasks.

To reproduce on a new Droplet:
\`\`\`bash
# Create gradient user with sudo privileges
adduser gradient
usermod -aG sudo gradient

# Add SSH public key for gradient (from vivobook and workshop)
mkdir -p /home/gradient/.ssh
chmod 700 /home/gradient/.ssh
echo "<id_vivobook_sls public key>" >> /home/gradient/.ssh/authorized_keys
echo "<id_workshop_sls public key>" >> /home/gradient/.ssh/authorized_keys
chmod 600 /home/gradient/.ssh/authorized_keys
chown -R gradient:gradient /home/gradient/.ssh
\`\`\`

The SSH keys for gradient are \`id_vivobook_sls\` and \`id_workshop_sls\` on
the respective development machines.

### Docker Installation
Docker is installed on this Droplet but the installation is NOT captured in
this snapshot. The DigitalOcean 1-click installer handled this automatically.

To install Docker on a fresh Ubuntu box:
\`\`\`bash
# Add Docker's official GPG key and repository
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list

# Install Docker Engine and buildx plugin
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add openclaw user to docker group (allows docker commands without sudo)
usermod -aG docker openclaw

# Enable and start Docker
systemctl enable docker
systemctl start docker
\`\`\`

Note: Installing docker-buildx-plugin here also satisfies the buildx requirement
for building the sandbox common image.

### Ada Workspace Git Remote
The git remote for the Ada workspace repo is NOT explicitly captured but is implied
by \`home/openclaw/.ssh/config\`. To verify or restore on a fresh deployment:
\`\`\`bash
# Check current remote
git -C /home/openclaw/.openclaw/workspace remote -v
# Expected: origin git@github.com:steveknipmeyer/sls-ada.git

# If missing, add it
git -C /home/openclaw/.openclaw/workspace remote add origin git@github.com:steveknipmeyer/sls-ada.git

# Clone fresh on a new deployment
git clone git@github.com:steveknipmeyer/sls-ada.git /home/openclaw/.openclaw/workspace
chown -R openclaw:openclaw /home/openclaw/.openclaw/workspace
\`\`\`

### Known Issues
- \`heartbeat.model\` override is broken in v2026.3.28 (GitHub issue #58137).
  Heartbeats fall back to the primary model. Monitor for fix in upcoming releases.

### VS Code IntelliSense for openclaw.json
The OpenClaw config schema is captured at \`config/schemas/openclaw.schema.json\`
on every harvest run. Connect it to \`openclaw.json\` via the workspace file
(\`openclaw.code-workspace\`) for intelligent editing with validation and autocomplete:
\`\`\`json
{
  "json.schemas": [
    {
      "fileMatch": ["/home/openclaw/.openclaw/openclaw.json"],
      "url": "file:///home/openclaw/.openclaw/projects/sls-config/config/schemas/openclaw.schema.json"
    }
  ]
}
\`\`\`
Re-run harvest after each OpenClaw update to refresh the schema.

### ⚠️ Critical: OpenClaw CLI Commands Must Run as the openclaw User

The gateway runs as the \`openclaw\` user and reads exclusively from
\`/home/openclaw/.openclaw/openclaw.json\`. The root user has a separate
\`/root/.openclaw/openclaw.json\` that the gateway **never reads**.

Running \`openclaw config set\` (or any config-writing CLI command) as root writes
to the wrong file with no effect on the running gateway. Worse, OpenClaw's atomic
write logic destroys any symlink at that path permanently.

**Always run openclaw CLI commands as the openclaw user:**
\`\`\`bash
# Correct
sudo -u openclaw openclaw config get agents.defaults.model
sudo -u openclaw openclaw config set <key> <value>
sudo -u openclaw openclaw agents list
sudo -u openclaw openclaw doctor

# Wrong — writes to /root/.openclaw/openclaw.json (gateway never reads this)
openclaw config set <key> <value>   # as root — DO NOT DO THIS
\`\`\`

Safe to run as root (read-only or system-level, not config):
\`\`\`bash
openclaw --version
sudo systemctl restart openclaw
sudo npm install -g openclaw@latest
\`\`\`

See MAINTENANCE.md for full explanation.

## Commit Convention

All commits to this repository use an author prefix in the message:
- \`Ada: <message>\` — commits made by Ada autonomously
- \`Steve: <message>\` — commits made by Steve manually

EOF

log "  ✓ README.md"

# =============================================================================
# SECTION 10: Check for unexpected files
#
# Compares the actual contents of STATE_DIR against the known expected file
# list. Any file not in the expected list is flagged as a warning — it may be
# a stale file from a previous harvest run (e.g. from a path rename) or an
# unintentional addition.
#
# This check preserves the git diff workflow: we do NOT wipe STATE_DIR before
# harvesting. Instead, unexpected files are surfaced here so you can decide
# whether to delete them before committing.
# =============================================================================

log ""
log "=== Checking for unexpected files ==="

find "${STATE_DIR}" -type f | sed "s|${CONFIG_ROOT}/||" | sort > /tmp/harvest-actual.txt

cat << 'EXPECTED' | sort > /tmp/harvest-expected.txt
config/state/README.md
config/state/docker-images.txt
config/state/local-workarounds.txt
config/state/openclaw-doctor.txt
config/state/ufw-status.txt
config/state/versions.txt
config/state/etc/apparmor.d/openclaw-codex-bwrap
config/state/etc/sls-web-server.env
config/state/etc/ssh/sshd_config
config/state/crontabs/root
config/state/home/openclaw/.profile
config/state/home/openclaw/.bashrc
config/state/home/openclaw/.npmrc
config/state/home/openclaw/.gitconfig
config/state/home/openclaw/.ssh/config
config/state/home/openclaw/dot-openclaw/openclaw.json
config/state/home/openclaw/dot-openclaw/exec-approvals.json
config/state/home/openclaw/openclaw.code-workspace
config/state/usr/local/bin/openclaw
config/state/opt/complete-openclaw-upgrade.sh
config/state/opt/protect-workspace.sh
config/state/opt/deprecated/setup-openclaw-domain.sh
config/state/opt/deprecated/update-openclaw.sh
config/state/opt/openclaw.env
config/state/opt/sls-billing-reader.json
config/state/opt/openclaw-cli.sh
config/state/opt/openclaw-tui.sh
config/state/opt/restart-openclaw.sh
config/state/opt/rotate-openclaw-gateway.sh
config/state/opt/setup-openclaw-domain.sh
config/state/opt/status-openclaw.sh
config/state/opt/tailscale-reauth.sh
config/state/opt/update-openclaw.sh
config/state/systemd/openclaw.service
config/state/systemd/sls-web-server.service
config/schemas/openclaw.schema.json
EXPECTED

UNEXPECTED=$(comm -23 /tmp/harvest-actual.txt /tmp/harvest-expected.txt)
if [ -z "$UNEXPECTED" ]; then
    log "  ✓ No unexpected files"
else
    log_warn "  ⚠ Unexpected files found — review before committing:"
    while IFS= read -r f; do
        log_warn "      $f"
    done <<< "$UNEXPECTED"
    log_warn "  → Add to expected list in harvest.sh or remove before committing:"
    log_warn "      rm /home/openclaw/.openclaw/projects/sls-config/<path>"
fi

rm -f /tmp/harvest-actual.txt /tmp/harvest-expected.txt

# =============================================================================
# SECTION 11: Scan for unredacted secrets
#
# Scans all harvested files for patterns that match known secret formats.
# Catches redaction failures before they can be committed to git.
#
# Patterns:
#   - 64 lowercase hex characters — the output of `openssl rand -hex 32`
#     Used for: gateway auth token, gateway remote token, hooks token.
#   - tskey- prefix — Tailscale pre-auth keys
#
# This is a last-resort safety net. If this fires, redaction has failed and
# you must NOT commit until the file is corrected.
# =============================================================================

log ""
log "=== Scanning for unredacted secrets ==="

SECRET_PATTERN='[0-9a-f]{64}|tskey-'
SECRETS_FOUND=0

while IFS= read -r file; do
    if grep -Pq "${SECRET_PATTERN}" "$file" 2>/dev/null; then
        log_warn "  ✗ POSSIBLE SECRET in: ${file#${CONFIG_ROOT}/}"
        SECRETS_FOUND=$((SECRETS_FOUND + 1))
    fi
done < <(find "${STATE_DIR}" -type f)

if [ "${SECRETS_FOUND}" -eq 0 ]; then
    log "  ✓ No secret patterns detected"
else
    log_warn ""
    log_warn "  ██████████████████████████████████████████████"
    log_warn "  ██  WARNING: POSSIBLE SECRETS DETECTED      ██"
    log_warn "  ██  Do NOT commit until resolved.           ██"
    log_warn "  ██████████████████████████████████████████████"
fi

# =============================================================================
# SECTION 12: Fix ownership
#
# Files harvested as root are owned by root. Fix ownership so the openclaw
# user can read, diff, and commit them via git.
# =============================================================================

log ""
log "=== Fixing ownership ==="

chown -R openclaw:openclaw "${CONFIG_ROOT}"
chmod -R u+r "${CONFIG_ROOT}"
log "  ✓ Ownership fixed: ${CONFIG_ROOT}"

# =============================================================================
# DONE
# =============================================================================

log ""
log "=== Harvest complete ==="
log "Snapshot written to: ${STATE_DIR}"
log ""
log "NEXT STEPS:"
log "  1. Review changes:  git -C ${CONFIG_ROOT} diff config/"
log "  2. Verify redaction:"
log "     grep -r 'REDACTED' ${STATE_DIR}/opt/openclaw.env"
log "     grep -r 'REDACTED' ${STATE_DIR}/etc/sls-web-server.env"
log "     grep -r 'REDACTED' ${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
log "     grep -r 'REDACTED' ${STATE_DIR}/home/openclaw/dot-openclaw/exec-approvals.json"
log "  3. Commit:"
log "     git -C ${CONFIG_ROOT} add config/"
log "     git -C ${CONFIG_ROOT} commit -m 'harvest snapshot ${DATE_ONLY}'"
log "     git -C ${CONFIG_ROOT} push"
log ""
log "WARNING: Always review diff before committing — secrets must be redacted."