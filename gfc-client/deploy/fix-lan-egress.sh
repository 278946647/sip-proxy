#!/usr/bin/env bash
# Fix LAN client: DNS ok but TCP/web timeout (sing-box gateway + strict_route).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
SB_CFG="${GFC_ETC}/sing-box.json"

[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

echo "==> fix LAN egress"

# 1) rp_filter breaks transparent proxy replies on LAN
if [[ -f /etc/sysctl.d/99-gfc-client.conf ]]; then
  grep -q 'rp_filter' /etc/sysctl.d/99-gfc-client.conf || cat >>/etc/sysctl.d/99-gfc-client.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
fi
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
for iface in ${GFC_LAN_IFACE:-bridge_lan} ${GFC_WAN_IFACE:-} gfctun; do
  [[ -n "$iface" ]] && sysctl -w "net.ipv4.conf.${iface}.rp_filter=0" >/dev/null 2>&1 || true
done
echo "    rp_filter: 0"

# 2) Re-apply nft + restart sing-box (gfctun forward + auto_redirect)
GFC_FORCE_NETWORK_APPLY=1 bash "$SCRIPT_DIR/gfc-network.sh" start

# 3) Patch live sing-box.json (no agent rebuild needed)
if [[ -f "$SB_CFG" ]]; then
  python3 - "$SB_CFG" "$GFC_ENV" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
env_path = Path(sys.argv[2])
env = {}
if env_path.is_file():
    for line in env_path.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()

wan = env.get("GFC_WAN_IFACE", "").strip()
lan = env.get("GFC_LAN_IFACE", "").strip()
if not lan and Path("/etc/gfc-client/network-roles.json").is_file():
    try:
        lan = json.loads(Path("/etc/gfc-client/network-roles.json").read_text()).get("lan", "")
    except Exception:
        pass

cfg = json.loads(path.read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), None)
route = cfg.setdefault("route", {})
changed = False

if tun and tun.get("auto_redirect"):
    ex = []
    if wan:
        ex.append(wan)
    if lan:
        ex.append(lan)
    if ex and tun.get("exclude_interface") != ex:
        tun["exclude_interface"] = ex
        changed = True

if wan and route.get("default_interface") != wan:
    route["default_interface"] = wan
    changed = True

rules = route.setdefault("rules", [])
if rules and rules[0].get("action") != "sniff":
    route["rules"] = [{"action": "sniff"}] + rules
    changed = True

if changed:
    path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
    print("    patched sing-box.json")
else:
    print("    sing-box.json already ok")
PY
  sing-box check -c "$SB_CFG" && systemctl restart gfc-sing-box.service
  echo "    sing-box restarted"
fi

# 4) Rulesets (split mode needs geoip-cn for IP routing)
missing=0
for f in geoip-cn.srs geosite-cn.srs geosite-geolocation-not-cn.srs; do
  [[ -f /var/lib/gfc-client/rules/$f ]] || missing=1
done
if [[ "$missing" == "1" ]]; then
  echo "    WARN: rule files missing — run: sudo bash deploy/fetch-meta-rules.sh"
  echo "           then: sudo systemctl restart gfc-agent.service"
fi

echo
bash "$SCRIPT_DIR/diagnose-lan.sh"
