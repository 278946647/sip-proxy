#!/usr/bin/env bash
# Restore LAN traffic through sing-box (proxy split) + faster MosDNS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
SB_CFG="${GFC_ETC}/sing-box.json"

[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

echo "==> fix proxy split + DNS"

# 1) sing-box: only exclude WAN (LAN must stay in auto_redirect)
if [[ -f "$SB_CFG" ]]; then
  python3 - "$SB_CFG" "$GFC_ENV" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
env = {}
for line in Path(sys.argv[2]).read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
wan = env.get("GFC_WAN_IFACE", "").strip()
cfg = json.loads(path.read_text())
tun = next((i for i in cfg.get("inbounds", []) if i.get("type") == "tun"), None)
if tun and tun.get("auto_redirect"):
    ex = [wan] if wan else []
    if tun.get("exclude_interface") != ex:
        if ex:
            tun["exclude_interface"] = ex
        elif "exclude_interface" in tun:
            del tun["exclude_interface"]
        path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
        print("    sing-box exclude_interface -> WAN only")
    else:
        print("    sing-box exclude_interface ok")
PY
  sing-box check -c "$SB_CFG" && systemctl restart gfc-sing-box.service
fi

# 2) MosDNS: re-render with faster upstream path
if [[ -x /usr/local/bin/gfc-agent ]] || command -v gfc-agent >/dev/null; then
  systemctl restart gfc-agent.service 2>/dev/null || true
  sleep 2
fi
if [[ -f "$SCRIPT_DIR/../internal/render/mosdns/mosdns.go" ]]; then
  :
fi
# Patch live mosdns config if agent not rebuilt yet
MOSCFG="${GFC_ETC}/mosdns/easymosdns/config.yaml"
if [[ -f "$MOSCFG" ]]; then
  python3 - "$MOSCFG" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
t = p.read_text()
t = t.replace("fast_fallback: 2500", "fast_fallback: 800")
t = t.replace("timeout: 6", "timeout: 4")
old = """            - primary:
                # 默认用分流服务器
                - forward_easymosdns
              secondary:
                # 超时用远程服务器
                - forward_remote
              fast_fallback: 800"""
new = """            - primary:
                - forward_remote
              secondary:
                - forward_local
              fast_fallback: 800"""
if old in t:
    t = t.replace(old, new)
t = t.replace("""            - ecs_local
            - forward_easymosdns""",
"""            - forward_remote
            - if: "[response_server_failed]"
              exec:
                - ecs_local
                - forward_local""")
if t != p.read_text():
    p.write_text(t)
    print("    mosdns config patched")
else:
    print("    mosdns config ok")
PY
  systemctl restart gfc-mosdns.service 2>/dev/null || true
fi

# 3) rp_filter still required for transparent proxy
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true

echo
echo "--- verify ---"
echo "box direct IP:"
curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo FAIL
echo
echo "sing-box exclude_interface:"
python3 -c "import json; t=next(i for i in json.load(open('$SB_CFG'))['inbounds'] if i['type']=='tun'); print(t.get('exclude_interface'))" 2>/dev/null || true
echo
echo "On PC: visit https://api.ipify.org — should show proxy node IP, not box WAN IP"
