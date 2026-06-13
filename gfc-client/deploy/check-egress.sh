#!/usr/bin/env bash
# Diagnose client egress (TUN gfctun + VLESS)
set -euo pipefail

echo "==> GFC client egress check"
echo

echo "--- services ---"
systemctl is-active gfc-client-sing-box gfc-mosdns gfc-client-agent gfc-client-api 2>/dev/null || true
echo

echo "--- gfctun / routes ---"
ip link show gfctun 2>/dev/null || echo "WARN: gfctun missing (idle or bypass mode)"
ip -4 route show table main | head -20
echo
echo "route to 1.1.1.1:"
ip -4 route get 1.1.1.1 2>/dev/null || true
echo

echo "--- sing-box config ---"
if [[ -f /etc/gfc-client/sing-box.json ]]; then
  python3 - <<'PY'
import json
from pathlib import Path
cfg = json.loads(Path("/etc/gfc-client/sing-box.json").read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), {})
print("  interface:", tun.get("interface_name"))
print("  auto_route:", tun.get("auto_route"))
print("  auto_redirect:", tun.get("auto_redirect"))
print("  node:", next((o.get("server") for o in cfg.get("outbounds", []) if o.get("type") == "vless"), "?"))
PY
  sing-box check -c /etc/gfc-client/sing-box.json && echo "  sing-box check: ok"
else
  echo "  WARN: no /etc/gfc-client/sing-box.json"
fi
echo

echo "--- nft ---"
nft list ruleset 2>/dev/null | grep -E 'sing-box|gfc_client|gfctun|gfc_dns' | head -30 || echo "  (no matching nft rules)"
echo

echo "--- egress IP (global sites) ---"
for url in "https://api.ipify.org" "https://ifconfig.me/ip"; do
  echo -n "  $url => "
  curl -fsS --max-time 12 "$url" 2>/dev/null || echo "FAIL"
  echo
done

echo "--- recent sing-box log ---"
tail -n 25 /var/log/gfc-client/sing-box.log 2>/dev/null || true
