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
  Use the complete upgrade script instead:

    sudo bash /opt/complete-openclaw-upgrade.sh

DOCUMENTATION:
  See MAINTENANCE.md -> "Update OpenClaw" -> "Quick path"

================================================================================
BLOCKING_MSG
exit 1
