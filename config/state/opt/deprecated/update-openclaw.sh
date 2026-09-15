#!/bin/bash
# DEPRECATED: /opt/update-openclaw.sh
# This script is INTENTIONALLY DISABLED to prevent unsafe upgrade behavior.

cat <<'BLOCKING_MSG'
================================================================================
 /opt/update-openclaw.sh is DISABLED

REASON:
  The old script used npm update -g which does not reliably install the
  latest version and does not verify axios for known compromised versions.

SAFE ALTERNATIVE:
  Prepare a reviewed exact stage with the complete upgrade script:

    sudo /opt/complete-openclaw-upgrade.sh --prepare <target-version>

  Copy the printed archive off-host and follow MAINTENANCE.md before using
  --execute. The old one-command upgrade path is intentionally unavailable.

DOCUMENTATION:
  See MAINTENANCE.md -> "Update OpenClaw" -> "Quick path"

================================================================================
BLOCKING_MSG
exit 1
