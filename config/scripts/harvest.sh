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
#         ssh/
#           sshd_config                 — SSH server hardening config
#       home/
#         openclaw/
#           .bashrc                     — openclaw user shell environment
#           .ssh/
#             config                    — SSH client config (deploy key stanza etc.)
#           dot-openclaw/
#             openclaw.json             — REDACTED: primary OpenClaw runtime config
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
#   IMPORTANT: Always review config/state/ before committing to git.
#   Run: git -C /home/openclaw/.openclaw/projects/sls-config diff config/state/
#   And: grep -r "REDACTED" /home/openclaw/.openclaw/projects/sls-config/config/state/opt/openclaw.env
#
# =============================================================================

set -euo pipefail

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

    # Patterns to redact: any KEY=value where KEY contains these strings
    local secret_patterns=(
        "API_KEY"
        "TOKEN"
        "SECRET"
        "PASSWORD"
        "CREDENTIAL"
    )

    for pattern in "${secret_patterns[@]}"; do
        # Match KEY=value (with or without quotes), replace value with REDACTED
        sed -i -E "s|(${pattern}[A-Z_]*)=(['\"]?)([^'\" ]+)(['\"]?)|\1=\2REDACTED\4|g" "$file"
    done

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
    "${STATE_DIR}/etc/ssh" \
    "${STATE_DIR}/home/openclaw/.ssh" \
    "${STATE_DIR}/home/openclaw/dot-openclaw" \
    "${STATE_DIR}/systemd"

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

# ---
# rotate-openclaw-gateway.sh — rotates the OpenClaw gateway auth token.
# REVIEWED AND CORRECTED: The original script (generated Mar 29) incorrectly
# attempted to copy /root/.openclaw/openclaw.json to /home/openclaw/.openclaw/openclaw.json.
# These are the same file via symlink — the copy was unnecessary and has been removed.
# The correct manual rotation procedure is documented in extras/MAINTENANCE.md.
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
# update-openclaw.sh — updates OpenClaw from npm and restarts the service.
# NOTE: This script uses `npm update -g openclaw` which may not install the
# latest version. Our tested update procedure uses `sudo npm install -g openclaw@latest`
# instead. See extras/MAINTENANCE.md for the recommended update procedure.
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/update-openclaw.sh" "${STATE_DIR}/opt/update-openclaw.sh"

# ---
# setup-openclaw-domain.sh — configures Caddy as a public HTTPS reverse proxy.
# STATUS: DISABLED — Caddy has been disabled on this deployment.
# This deployment uses Tailscale exclusively for access (zero public ports).
# Caddy was part of the original DigitalOcean installer setup for public access
# before Tailscale was configured. It has been stopped and disabled:
#   sudo systemctl stop caddy
#   sudo systemctl disable caddy
# This script is retained for reference only — do NOT run it.
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/setup-openclaw-domain.sh" "${STATE_DIR}/opt/setup-openclaw-domain.sh"

# ---
# openclaw-cli.sh — helper to run OpenClaw CLI commands as the openclaw user.
# Runs: su - openclaw -c "openclaw $*"
# Useful when running CLI commands as root and needing to switch to openclaw user.
# Origin: DigitalOcean installer (Mar 20), not modified.
# ---
harvest_file "/opt/openclaw-cli.sh" "${STATE_DIR}/opt/openclaw-cli.sh"

# ---
# openclaw-tui.sh — launches the OpenClaw TUI with the gateway token.
# WARNING: This script reads the gateway token from /opt/openclaw.env and
# passes it as a command-line argument (--token=<value>). The token will be
# visible in `ps aux` output while the TUI is running. Use with caution in
# shared environments.
# Origin: DigitalOcean installer (Mar 20), not modified.
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
# SECTION 3: openclaw user home files
#
# User-level configuration for the openclaw account.
# =============================================================================

log ""
log "=== /home/openclaw ==="

# .bashrc — shell environment for the openclaw user.
# Contains: NODE_COMPILE_CACHE and OPENCLAW_NO_RESPAWN startup optimizations
# recommended by `openclaw doctor` for low-power/VM hosts.
harvest_file "/home/openclaw/.bashrc" "${STATE_DIR}/home/openclaw/.bashrc"

# .ssh/config — SSH client configuration.
# Contains the deploy key stanza for github.com (id_ed25519_sls)
# which allows git push to the ada repo without agent forwarding.
# This enables both manual commits (from VS Code/terminal) and automated commits
# (from Ada via cron) to use the same deploy key.
# NOTE: Private keys are NOT harvested — only the config file.
harvest_file "/home/openclaw/.ssh/config" "${STATE_DIR}/home/openclaw/.ssh/config"

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
# and hooks.token. Redaction uses jq to target exact JSON paths.
harvest_file "/home/openclaw/.openclaw/openclaw.json" "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
jq '
    .gateway.auth.token = "REDACTED" |
    .gateway.remote.token = "REDACTED" |
    .hooks.token = "REDACTED"
' "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json" > /tmp/openclaw.json.redacted \
&& mv /tmp/openclaw.json.redacted "${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
log "  → Redacted secrets in openclaw.json (jq)"

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
# NOTE: Uses /usr/bin/openclaw directly (bypasses the root guard stub) since
# harvest runs as root and schema generation is a read-only operation.
# =============================================================================

log ""
log "=== OpenClaw config schema ==="

if /usr/bin/openclaw config schema > "${SCHEMA_DIR}/openclaw.schema.json" 2>/dev/null; then
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
    openclaw --version 2>/dev/null || echo "openclaw: not found in PATH"
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

# Run non-interactively to avoid prompts
capture_command "${STATE_DIR}/openclaw-doctor.txt" \
    bash -c 'echo "" | openclaw doctor 2>&1 || true'

# =============================================================================
# SECTION 9: Generate README.md
#
# Auto-generated index for this snapshot. Describes the contents and
# provides context for someone reproducing the environment.
# =============================================================================

log ""
log "=== Generating README.md ==="

OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | grep -oP '\d{4}\.\d+\.\d+' || echo "unknown")

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
| \`state/etc/ssh/sshd_config\` | Custom | Hardened SSH server config |
| \`state/home/openclaw/.bashrc\` | Custom | openclaw user shell environment |
| \`state/home/openclaw/.ssh/config\` | Custom | SSH client config (deploy key stanza) |
| \`state/home/openclaw/dot-openclaw/openclaw.json\` | Custom | Primary OpenClaw runtime config (REDACTED secrets) |
| \`state/usr/local/bin/openclaw\` | Custom | Root guard stub — blocks openclaw CLI as root |
| \`state/systemd/openclaw.service\` | DO installer | Root-level systemd service definition |
| \`state/systemd/sls-web-server.service\` | Custom | Express web server systemd service |
| \`state/versions.txt\` | Generated | Runtime version snapshot |
| \`state/docker-images.txt\` | Generated | Docker images present on host |
| \`state/ufw-status.txt\` | Generated | Firewall rules |
| \`state/openclaw-doctor.txt\` | Generated | openclaw doctor output at harvest time |
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

### Secrets
The following secrets are NOT included in this snapshot and must be configured manually:
- \`ANTHROPIC_API_KEY\` — set in \`/opt/openclaw.env\`
- Gateway \`auth.token\` — set in \`~/.openclaw/openclaw.json\`
- Gateway \`remote.token\` — set in \`~/.openclaw/openclaw.json\`
- Hooks \`token\` — set in \`~/.openclaw/openclaw.json\` and \`/opt/openclaw.env\` as \`OPENCLAW_HOOKS_TOKEN\`. Must be different from the gateway auth token.
- \`~/.openclaw/gateway-token.txt\` — created by installer, contains gateway token (chmod 600)
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

### ada Workspace Git Remote
The git remote for the Ada workspace repo is NOT explicitly captured but is implied
by \`home/openclaw/.ssh/config\`. To verify or restore on a fresh deployment:
\`\`\`bash
# Check current remote
git -C /home/openclaw/.openclaw/workspaces/ada remote -v
# Expected: origin git@github.com:steveknipmeyer/sls-ada.git

# If missing, add it
git -C /home/openclaw/.openclaw/workspaces/ada remote add origin git@github.com:steveknipmeyer/sls-ada.git

# Clone fresh on a new deployment
git clone git@github.com:steveknipmeyer/sls-ada.git /home/openclaw/.openclaw/workspaces/ada
chown -R openclaw:openclaw /home/openclaw/.openclaw/workspaces/ada
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
config/state/openclaw-doctor.txt
config/state/ufw-status.txt
config/state/versions.txt
config/state/etc/ssh/sshd_config
config/state/home/openclaw/.bashrc
config/state/home/openclaw/.ssh/config
config/state/home/openclaw/dot-openclaw/openclaw.json
config/state/home/openclaw/openclaw.code-workspace
config/state/usr/local/bin/openclaw
config/state/opt/openclaw.env
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
# Pattern: 64 lowercase hex characters — the output of `openssl rand -hex 32`
# Used for: gateway auth token, gateway remote token, hooks token.
#
# This is a last-resort safety net. If this fires, redaction has failed and
# you must NOT commit until the file is corrected.
# =============================================================================

log ""
log "=== Scanning for unredacted secrets ==="

SECRET_PATTERN='[0-9a-f]{64}'
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
log "     grep -r 'REDACTED' ${STATE_DIR}/home/openclaw/dot-openclaw/openclaw.json"
log "  3. Commit:"
log "     git -C ${CONFIG_ROOT} add config/"
log "     git -C ${CONFIG_ROOT} commit -m 'harvest snapshot ${DATE_ONLY}'"
log "     git -C ${CONFIG_ROOT} push"
log ""
log "WARNING: Always review diff before committing — secrets must be redacted."