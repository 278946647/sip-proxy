#!/usr/bin/env bash
# Ensure sing-box.json has WAN binding (default_interface + bind_interface + gvisor stack).
set -euo pipefail

GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
CFG="${GFC_SINGBOX_CONFIG:-/etc/gfc-client/sing-box.json}"
ROLES="${GFC_ETC:-/etc/gfc-client}/network-roles.json"

[[ -r "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

if [[ ! -f "$CFG" ]]; then
  echo "    patch-singbox-wan: skip (no $CFG)" >&2
  exit 0
fi

WAN="${GFC_WAN_IFACE:-}"
if [[ -z "$WAN" && -f "$ROLES" ]]; then
  WAN="$(python3 -c "import json; print(json.load(open('$ROLES')).get('wan','').strip())" 2>/dev/null || true)"
fi
if [[ -z "$WAN" ]]; then
  WAN="$(ip -4 route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
if [[ -z "$WAN" ]]; then
  for dst in 1.1.1.1 8.8.8.8; do
    WAN="$(ip -4 route get "$dst" 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [[ -n "$WAN" ]] && break
  done
fi
if [[ -z "$WAN" ]]; then
  echo "ERROR: WAN unknown — set GFC_WAN_IFACE=ens160 in $GFC_ENV" >&2
  exit 1
fi

python3 - "$CFG" "$WAN" <<'PY'
import json, sys
from pathlib import Path

path, wan = Path(sys.argv[1]), sys.argv[2]
cfg = json.loads(path.read_text())
changed = False

route = cfg.setdefault("route", {})
if route.get("default_interface") != wan:
    route["default_interface"] = wan
    changed = True
if route.get("auto_detect_interface") is not False:
    route["auto_detect_interface"] = False
    changed = True

for ob in cfg.get("outbounds", []):
    t, tag = ob.get("type"), ob.get("tag")
    if t == "vless" or (t == "direct" and tag == "direct"):
        if ob.get("bind_interface") != wan:
            ob["bind_interface"] = wan
            changed = True

for ib in cfg.get("inbounds", []):
    if ib.get("type") != "tun":
        continue
    if ib.get("stack") != "gvisor":
        ib["stack"] = "gvisor"
        changed = True
    if ib.get("auto_route") is not False:
        ib["auto_route"] = False
        changed = True
    if ib.get("auto_redirect") is not False:
        ib["auto_redirect"] = False
        changed = True

if changed:
    path.write_text(json.dumps(cfg, indent=2) + "\n")
    print(f"    patched sing-box.json (wan={wan}, stack=gvisor)")
else:
    print(f"    sing-box.json wan={wan} ok")
PY

if command -v sing-box >/dev/null; then
  sing-box check -c "$CFG"
fi
