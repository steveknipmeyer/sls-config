#!/bin/bash

gateway_token=$(jq -r '.gateway.remote.token // .gateway.auth.token // empty' /home/openclaw/.openclaw/openclaw.json 2>/dev/null)

if [ -z "$gateway_token" ]; then
	echo "Gateway token not found in /home/openclaw/.openclaw/openclaw.json"
	exit 1
fi

/opt/openclaw-cli.sh tui --token=${gateway_token}
