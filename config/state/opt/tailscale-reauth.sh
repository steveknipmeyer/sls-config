#!/bin/bash
# Emergency Tailscale re-authentication
# Use if Tailscale loses connectivity to tailnet
# Run via: sudo bash /opt/tailscale-reauth.sh
tailscale up --authkey=REDACTED --force-reauth
