#!/bin/bash
# Force node-agent to re-apply config (sing-box + routes) on next poll.
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if p.suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
_COMMON="$(cd "$(dirname "$_self")" && pwd)/_common.sh"
if [[ -f "$_COMMON" ]]; then
  # shellcheck source=deploy/node/_common.sh
  source "$_COMMON"
else
  gfc_render_singbox_from_bundle() {
    local gfc_root=${1:-/opt/gfc-node}
    local venv_py="${gfc_root}/node-agent/.venv/bin/python"
    local bundle="${gfc_root}/node-agent/state/dataplane/config_bundle.json"
    [[ -f "$bundle" && -x "$venv_py" ]] || return 1
    GFC_ROOT="$gfc_root" BUNDLE="$bundle" OUT="/etc/gfc-node/sing-box.json" "$venv_py" - <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, f"{os.environ['GFC_ROOT']}/node-agent")
from node_agent.singbox import render_singbox_config
from node_agent.socks_health import evaluate_socks_dns_health
bundle = Path(os.environ["BUNDLE"])
data = json.loads(bundle.read_text(encoding="utf-8"))
socks_ok = evaluate_socks_dns_health(data, bundle.parent)
cfg = render_singbox_config(data.get("dataplane") or {}, socks_dns_ok=socks_ok)
Path(os.environ["OUT"]).write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
PY
  }
  gfc_clear_applied_version() {
    python3 -c "import json;p='${1:-/opt/gfc-node/node-agent/state/node_state.json}';d=json.load(open(p));d.pop('applied_version',None);json.dump(d,open(p,'w'),indent=2);print('cleared',p)"
  }
fi
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
STATE="${STATE_FILE:-${GFC_ROOT}/node-agent/state/node_state.json}"

if [[ ! -f "$STATE" ]]; then
  echo "missing $STATE"
  exit 1
fi

if [[ -d /var/socks/node-agent ]]; then
  echo "==> Sync /var/socks/node-agent -> ${GFC_ROOT}/node-agent"
  rsync -a /var/socks/node-agent/ "${GFC_ROOT}/node-agent/" --exclude .venv --exclude state
  if [[ -x "${GFC_ROOT}/node-agent/.venv/bin/pip" ]]; then
    "${GFC_ROOT}/node-agent/.venv/bin/pip" install -q -r "${GFC_ROOT}/node-agent/requirements.txt" || true
  fi
else
  echo "WARN: /var/socks/node-agent missing — using ${GFC_ROOT}/node-agent as-is"
fi

if grep -qE '"timeout"|connect_timeout' "${GFC_ROOT}/node-agent/node_agent/singbox.py" 2>/dev/null; then
  echo "ERROR: node_agent/singbox.py 过旧（含 sing-box 1.13.4 不支持的 timeout 字段）。"
  echo "       请把开发机最新 node-agent 同步到 /var/socks 后执行:"
  echo "       sudo python3 /var/socks/deploy/node/repair_forward_node.py"
  exit 1
fi

gfc_render_singbox_from_bundle "$GFC_ROOT" || true
gfc_clear_applied_version "$STATE"

echo "==> sing-box check (before agent restart)"
sing-box check -c /etc/gfc-node/sing-box.json 2>&1 || true

systemctl restart gfc-node-agent
echo "==> wait for apply..."
sleep 12
journalctl -u gfc-node-agent -n 15 --no-pager
echo "==> sing-box status"
systemctl status gfc-sing-box --no-pager | head -12 || true
sing-box check -c /etc/gfc-node/sing-box.json && echo "sing-box OK"
echo "==> routes"
ip route show | grep -E '10\.10\.10|172\.16\.16' || ip route show
