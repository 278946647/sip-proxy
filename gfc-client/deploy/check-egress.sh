#!/usr/bin/env bash
# Diagnose client egress (TUN gfctun + VLESS)
set -euo pipefail

echo "==> GFC client egress check"
echo

echo "--- services ---"
systemctl is-active gfc-sing-box gfc-routing gfc-mosdns gfc-agent gfc-web gfc-network 2>/dev/null || true
echo

echo "--- policy routing ---"
ip -4 rule list 2>/dev/null | grep -E '2023|2022' || echo "  (no fwmark rules)"
echo "table 2022:"
ip -4 route show table 2022 2>/dev/null | head -5 || echo "  (table 2022 empty)"
echo

echo "--- sing-box process ---"
ps -o user=,pid=,cmd= -C sing-box 2>/dev/null | head -3 || echo "  (sing-box not running)"
id singbox 2>/dev/null || echo "  WARN: singbox user missing"
echo

echo "--- policy nft (uid exempt) ---"
if [[ -f /etc/gfc-client/nftables-policy.conf ]]; then
  grep -E 'skuid 65354|skuid 65353|dport \{ 53' /etc/gfc-client/nftables-policy.conf | head -6
else
  echo "  WARN: no nftables-policy.conf"
fi
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
import json, os
from pathlib import Path
cfg = json.loads(Path("/etc/gfc-client/sing-box.json").read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), {})
print("  interface:", tun.get("interface_name"))
print("  auto_route:", tun.get("auto_route"), "(expect False)")
print("  auto_redirect:", tun.get("auto_redirect"), "(expect False)")
print("  stack:", tun.get("stack"), "(expect gvisor for fwmark policy)")
print("  default_interface:", cfg.get("route", {}).get("default_interface"))
print("  node:", next((o.get("server") for o in cfg.get("outbounds", []) if o.get("type") == "vless"), "?"))
print("  routing_scheme:", os.environ.get("GFC_ROUTING_SCHEME", "kernel-split"))
rules = cfg.get("route", {}).get("rules", [])
has_geo = any("rule_set" in r for r in rules)
print("  sing-box geo split:", has_geo, "(expect False for scheme B)")
PY
  sing-box check -c /etc/gfc-client/sing-box.json && echo "  sing-box check: ok"
else
  echo "  WARN: no /etc/gfc-client/sing-box.json"
fi
echo

echo "--- policy nft ---"
if [[ -f /etc/gfc-client/nftables-policy.conf ]]; then
  echo "  scheme: $(grep -oE 'Scheme [AB]|kernel-split|tun-all' /etc/gfc-client/nftables-policy.conf | head -1 || echo kernel-split)"
  echo "  cn_ip audit lines: $(grep -vc '^#' /etc/gfc-client/nftables-cn-ip.set 2>/dev/null || echo 0)"
  echo "  cn_ip load batches: $(grep -c 'add element inet gfc_client_mangle cn_ip' /etc/gfc-client/nftables-cn-ip-load.nft 2>/dev/null || echo 0)"
  grep -E 'classify|cn_ip|skuid 6535' /etc/gfc-client/nftables-policy.conf | head -8
else
  echo "  WARN: no nftables-policy.conf"
fi
echo

echo "--- VLESS (relay node) ---"
if [[ -x /opt/gfc-client/deploy/check-vless.sh ]]; then
  bash /opt/gfc-client/deploy/check-vless.sh || true
elif [[ -x "$(dirname "$0")/check-vless.sh" ]]; then
  bash "$(dirname "$0")/check-vless.sh" || true
fi
echo

echo "--- egress IP (global sites) ---"
for url in "https://api.ipify.org" "https://ifconfig.me/ip"; do
  echo -n "  $url => "
  curl -fsS --max-time 12 "$url" 2>/dev/null || echo "FAIL"
  echo
done

echo "--- recent sing-box log ---"
tail -n 25 /var/log/gfc-client/sing-box.log 2>/dev/null || true
