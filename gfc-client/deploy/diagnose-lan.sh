#!/usr/bin/env bash
# Diagnose LAN client: DNS ok but browser/tcp fails
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
LAN=$(python3 -c "import json;print(json.load(open('${GFC_ETC}/network-roles.json')).get('lan',''))" 2>/dev/null || echo "bridge_lan")
WAN=$(python3 -c "import json;print(json.load(open('${GFC_ETC}/network-roles.json')).get('wan',''))" 2>/dev/null || echo "")

echo "==> LAN client diagnose (lan=$LAN wan=$WAN)"
echo

echo "--- ip_forward ---"
sysctl net.ipv4.ip_forward
echo

echo "--- forward chain (need lan<->gfctun in gateway mode) ---"
nft list chain inet gfc_client_filter forward 2>/dev/null || echo "no forward chain"
echo

echo "--- masquerade ---"
nft list chain ip gfc_client_nat postrouting 2>/dev/null || echo "no nat chain"
echo

echo "--- sing-box tun ---"
ip link show gfctun 2>/dev/null || echo "gfctun down"
python3 - <<'PY' 2>/dev/null || true
import json
from pathlib import Path
p = Path("/etc/gfc-client/sing-box.json")
if p.is_file():
    c = json.loads(p.read_text())
    t = next((i for i in c.get("inbounds",[]) if i.get("type")=="tun"), {})
    print("  auto_route:", t.get("auto_route"))
    print("  auto_redirect:", t.get("auto_redirect"))
PY
echo

echo "--- sing-box nft (auto_redirect) ---"
nft list ruleset 2>/dev/null | grep -E 'sing-box|gfctun' | head -15 || echo "(none)"
echo

echo "--- test from box ---"
curl -fsS --connect-timeout 5 -o /dev/null -w "baidu http: %{http_code}\n" http://www.baidu.com 2>/dev/null || echo "baidu http: FAIL"
echo

echo "On PC while running next command, try: curl --connect-timeout 5 http://www.baidu.com"
echo "tcpdump (5 packets):"
timeout 15 tcpdump -ni "$LAN" 'tcp and (port 80 or port 443)' -c 5 2>/dev/null || echo "tcpdump skipped"
