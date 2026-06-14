#!/usr/bin/env bash
# Diagnose LAN client: DNS ok but browser/tcp fails
set -euo pipefail

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
LAN=$(python3 -c "import json;print(json.load(open('${GFC_ETC}/network-roles.json')).get('lan',''))" 2>/dev/null || echo "bridge_lan")
WAN=$(python3 -c "import json;print(json.load(open('${GFC_ETC}/network-roles.json')).get('wan',''))" 2>/dev/null || echo "")

echo "==> LAN client diagnose (lan=$LAN wan=$WAN)"
echo

echo "--- rp_filter (must be 0 for transparent proxy) ---"
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter 2>/dev/null || true
[[ -n "$LAN" ]] && sysctl "net.ipv4.conf.${LAN}.rp_filter" 2>/dev/null || true
echo

echo "--- ip_forward ---"
sysctl net.ipv4.ip_forward
echo

echo "--- forward chain ---"
nft list chain inet gfc_client_filter forward 2>/dev/null || echo "no forward chain"
echo

echo "--- sing-box redirect rules ---"
nft list ruleset 2>/dev/null | grep -E 'sing-box|redirect|gfctun' | head -20 || echo "(none — sing-box idle or auto_redirect off)"
echo

echo "--- sing-box tun ---"
ip link show gfctun 2>/dev/null || echo "gfctun down"
if [[ -f /etc/gfc-client/sing-box.json ]]; then
  python3 - <<'PY'
import json
from pathlib import Path
cfg = json.loads(Path("/etc/gfc-client/sing-box.json").read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), {})
route = cfg.get("route", {})
print("  auto_route:", tun.get("auto_route"))
print("  auto_redirect:", tun.get("auto_redirect"))
print("  strict_route:", tun.get("strict_route"))
print("  exclude_interface:", tun.get("exclude_interface"))
print("  default_interface:", route.get("default_interface"))
print("  sniff:", (route.get("rules") or [{}])[0].get("action") == "sniff")
print("  rule_sets:", len(route.get("rule_set") or []))
print("  node:", next((o.get("server") for o in cfg.get("outbounds", []) if o.get("type") == "vless"), "idle"))
PY
fi
echo

echo "--- rule files ---"
ls -la /var/lib/gfc-client/rules/*.srs 2>/dev/null || echo "WARN: no .srs rule files"
echo

echo "--- box egress ---"
curl -fsS --connect-timeout 5 -o /dev/null -w "baidu http: %{http_code}\n" http://www.baidu.com 2>/dev/null || echo "baidu http: FAIL"
echo

echo "While PC runs: curl --connect-timeout 5 http://www.baidu.com"
echo "Run on box (compare LAN vs WAN):"
echo "  tcpdump -ni $LAN host <PC_IP> and tcp port 80"
[[ -n "$WAN" ]] && echo "  tcpdump -ni $WAN host <PC_IP> and tcp port 80"
echo
timeout 12 tcpdump -ni "$LAN" 'tcp and (port 80 or port 443)' -c 3 2>/dev/null || echo "tcpdump skipped"
