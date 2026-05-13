#!/bin/bash
echo "=== OpenClaw Gateway Status ==="
systemctl status openclaw --no-pager

echo ""
echo "=== Gateway Auth Source ==="
echo "Canonical source: /home/openclaw/.openclaw/openclaw.json"
echo "Environment override should be absent."

echo ""
echo "=== Gateway Env Check ==="
pid=$(systemctl show openclaw -p MainPID --value)
if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    if tr '\0' '\n' < "/proc/$pid/environ" | grep -q '^OPENCLAW_GATEWAY_TOKEN='; then
        echo "WARNING: OPENCLAW_GATEWAY_TOKEN is present in the live process env"
    else
        echo "OK: OPENCLAW_GATEWAY_TOKEN absent from live process env"
    fi
    tr '\0' '\n' < "/proc/$pid/environ" | grep '^OPENCLAW_SERVICE_KIND=' || true
else
    echo "Service not running"
fi

echo ""
echo "=== Gateway URL ==="
myip=$(hostname -I | awk '{print$1}')
echo "http://$myip:18789"