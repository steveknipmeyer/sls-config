#!/bin/bash
# Launch the OpenClaw terminal UI as the openclaw user.
su - openclaw -c "openclaw tui $*"
