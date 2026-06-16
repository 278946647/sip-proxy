#!/usr/bin/env bash
# Re-render active sing-box/mosdns from bundle (activated device). Do NOT use gfc-bootstrap alone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

echo "==> reapply-active (from ${PKG_ROOT})"

if [[ -x "$PKG_ROOT/bin/gfc-api" ]]; then
  echo "    install binaries -> /usr/local/bin"
  install -m 755 "$PKG_ROOT/bin/gfc-api" "$PKG_ROOT/bin/gfc-agent" "$PKG_ROOT/bin/gfc-bootstrap" /usr/local/bin/
fi
if [[ -d "$PKG_ROOT/web-static" ]]; then
  rm -rf "$GFC_ROOT/web"
  cp -a "$PKG_ROOT/web-static" "$GFC_ROOT/web"
fi
rsync -a "$PKG_ROOT/deploy/" "$GFC_ROOT/deploy/"
chmod +x "$GFC_ROOT/deploy"/*.sh

bash "$SCRIPT_DIR/install-gfc-units.sh"
systemctl daemon-reload

if [[ ! -f /var/lib/gfc-client/state/config_bundle.json ]]; then
  echo "ERROR: no config bundle — flash line code first" >&2
  exit 1
fi

echo "    purge sing-box auto_route / table 2022"
bash "$SCRIPT_DIR/singbox-nft-cleanup.sh" 2>/dev/null || true
# shellcheck source=lib-policy-routing.sh
source "$SCRIPT_DIR/lib-policy-routing.sh"
purge_singbox_policy_routes

echo "    reapply from bundle (gfc-bootstrap --reapply)"
gfc-bootstrap --reapply

echo "    patch sing-box WAN binding"
bash "$SCRIPT_DIR/patch-singbox-wan.sh"
systemctl restart gfc-sing-box.service 2>/dev/null || true

bash "$SCRIPT_DIR/apply-network.sh"

echo "    policy routing (post-netplan)"
bash "$SCRIPT_DIR/gfc-routing.sh" start

echo "==> reapply-active done"
systemctl is-active gfc-mosdns gfc-sing-box gfc-routing 2>/dev/null || true

python3 - <<'PY'
import json
p="/etc/gfc-client/sing-box.json"
cfg=json.load(open(p))
inb=[i for i in cfg.get("inbounds",[]) if i.get("type")=="tun"]
if not inb:
    print("    WARN: no tun inbound (idle config?)")
else:
    t=inb[0]
    print("    sing-box tun auto_route:", t.get("auto_route"), "auto_redirect:", t.get("auto_redirect"))
print("    default_interface:", cfg.get("route",{}).get("default_interface"))
PY

ip -4 rule list 2>/dev/null | grep 2023 || echo "    WARN: no fwmark rule"
ip -4 route show table 2022 2>/dev/null | head -3 || true
