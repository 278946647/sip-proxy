#!/usr/bin/env bash
# Diagnose whether client traffic exits via VLESS→forward node→SOCKS or local WAN.
set -euo pipefail

echo "==> GFC client egress check"
echo

echo "--- services ---"
systemctl is-active gfc-client-sing-box gfc-mosdns gfc-client-agent 2>/dev/null || true
echo

echo "--- gfc0 / routes ---"
ip link show gfc0 2>/dev/null || echo "WARN: gfc0 missing"
ip -4 route show table main | head -20
echo
echo "route to 1.1.1.1:"
ip -4 route get 1.1.1.1 2>/dev/null || true
echo

echo "--- sing-box config (gateway / auto_redirect) ---"
if [[ -f /etc/gfc-client/sing-box.json ]]; then
  python3 - <<'PY'
import json
from pathlib import Path
cfg = json.loads(Path("/etc/gfc-client/sing-box.json").read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), {})
print("  auto_route:", tun.get("auto_route"))
print("  auto_redirect:", tun.get("auto_redirect"))
print("  node:", next((o.get("server") for o in cfg.get("outbounds", []) if o.get("type") == "vless"), "?"))
PY
  sing-box check -c /etc/gfc-client/sing-box.json && echo "  sing-box check: ok"
else
  echo "  WARN: no /etc/gfc-client/sing-box.json"
fi
echo

echo "--- nft (sing-box redirect + client NAT) ---"
nft list ruleset 2>/dev/null | grep -E 'sing-box|gfc_client|gfc0|auto_redirect' | head -30 || echo "  (no matching nft rules)"
echo

echo "--- sing-box connections to forward node ---"
NODE=$(python3 - <<'PY'
import json
from pathlib import Path
try:
    cfg = json.loads(Path("/etc/gfc-client/sing-box.json").read_text())
    print(next((o.get("server") for o in cfg.get("outbounds", []) if o.get("type") == "vless"), ""))
except Exception:
    pass
PY
)
if [[ -n "$NODE" ]]; then
  ss -tn state established "( dst $NODE )" 2>/dev/null || true
fi
echo

echo "--- egress IP tests (use global sites; .cn goes direct in split mode) ---"
for url in "https://api.ipify.org" "https://ifconfig.me/ip"; do
  echo -n "  $url => "
  curl -fsS --max-time 12 "$url" 2>/dev/null || echo "FAIL"
  echo
done

echo "--- recent sing-box log ---"
tail -n 25 /var/log/gfc-client/sing-box.log 2>/dev/null || true
echo
echo "If egress IP equals this box WAN (not SOCKS exit), check:"
echo "  1) auto_redirect=true in sing-box.json (gateway mode)"
echo "  2) forward node sing-box has client-<lineId> user + SOCKS outbound"
echo "  3) test global site (google.com / ipify), not .cn (split routing = direct)"
echo "  4) on forward node: tail /var/log/gfc-node/sing-box.log during curl"
