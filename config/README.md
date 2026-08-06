# Host Reconstruction

This directory separates desired dependencies from observed host state. Keep
those roles distinct when rebuilding or reviewing drift.

## Sources of Truth

1. `packages/apt-required.txt` declares required packages available from the
   Ubuntu archive. Entries are package names, not a frozen dpkg replay list.
2. `packages/pipx-tools.txt` declares exact Python CLI versions. Each tool is
   installed in an isolated pipx environment owned by `openclaw`.
3. `packages/openclaw-plugins.txt` declares exact external OpenClaw plugin
   versions compatible with the pinned host core.
4. `state/` is a harvested snapshot of configuration and observed state. Its
   package inventories support audit and comparison; they are not installers.
5. Secrets, external account enrollment, cloud controls, and third-party apt
   repositories require deliberate manual provisioning.

## Dependency Bootstrap

Prerequisites are Ubuntu with this repository present at
`/home/openclaw/.openclaw/projects/sls-config` and an existing `openclaw` user.
Run the bootstrap from a root shell:

```bash
bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/bootstrap-packages.sh
```

The script is convergent: apt ensures declared packages are installed; pipx
leaves matching versions unchanged and force-replaces only missing or drifting
tools. It does not install Python CLIs into the system Python environment.

Verify the user-scoped executables directly:

```bash
/home/openclaw/.local/bin/ruff --version
/home/openclaw/.local/bin/black --version
```

The existing `openclaw` `.profile` adds `$HOME/.local/bin` to login shells.
The bootstrap deliberately does not run `pipx ensurepath` or modify shell
startup files. Start a new login shell before relying on bare `ruff` or
`black` commands.

After installing the pinned OpenClaw core, run the external plugin bootstrap
as the `openclaw` user, never as root:

```bash
bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/bootstrap-openclaw-plugins.sh
```

The plugin bootstrap is convergent. It leaves an exact matching install record
unchanged and reinstalls missing or drifting plugins with `--force --pin`.
Update the core and plugin pins together when compatibility requirements
change; the script deliberately does not follow npm's floating latest version.

## Harvested Package State

Run the harvest from a root shell after dependency or host configuration
changes:

```bash
bash /home/openclaw/.openclaw/projects/sls-config/config/scripts/harvest.sh
```

The generated package artifacts have different diagnostic purposes:

- `state/apt-manual.txt` records packages marked as manually selected.
- `state/dpkg-packages.txt` records every installed dpkg package with version
  and architecture.
- `state/pipx-tools.json` records structured pipx state for the `openclaw`
  account.
- `state/versions.txt` records direct runtime and tool version output.

Never feed `apt-manual.txt` or `dpkg-packages.txt` back into apt. They include
historical, transitive, image-provided, and externally sourced packages that
are useful for comparison but are not all desired dependencies.

## Fresh Host Sequence

1. Create the `openclaw` account and place the tracked repositories at their
   canonical paths.
2. Run `bootstrap-packages.sh` to install Ubuntu dependencies and pinned Python
   CLIs.
3. Provision vendor-managed runtimes and repositories separately: Docker,
   Tailscale, Node.js/OpenClaw, and Himalaya.
4. As the `openclaw` user, run `scripts/bootstrap-openclaw-plugins.sh` after the
   pinned OpenClaw core is installed.
5. Review `state/README.md`, then restore each tracked system file with its
   documented owner, mode, and service context. Do not copy the entire snapshot
   blindly.
6. Provision new secrets directly on the host and complete OAuth, Telegram,
   email, GitHub SSH, Tailscale, and other external enrollment flows.
7. Recreate and verify DigitalOcean firewall policy, UFW rules, systemd units,
   cron, sandbox images, and service health.
8. Run `harvest.sh` and compare the new observed state with the tracked
   snapshot. Resolve unexplained drift before treating the rebuild as complete.

## Boundaries

The bootstrap intentionally does not modify network exposure, firewall policy,
systemd services, cron, users or groups, external apt repositories, cloud
resources, or credentials. Those operations can change trust boundaries or
depend on deployment-specific secrets and therefore remain controlled steps.
