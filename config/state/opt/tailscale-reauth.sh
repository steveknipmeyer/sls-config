#!/bin/bash
# Emergency Tailscale re-authentication
# Use if Tailscale loses connectivity to tailnet
# Run via: sudo bash /opt/tailscale-reauth.sh
tailscale up --authkey=tskey-auth-kQN23GGFnx11CNTRL-mhduy375LEZTuQXiidKaEZpcrd7oTZV65 --force-reauth
