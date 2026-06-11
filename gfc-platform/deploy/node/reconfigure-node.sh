#!/usr/bin/env bash
# 已安装节点重新配置（无需重装，不改编译代码）
#   sudo bash deploy/node/reconfigure-node.sh
#   sudo bash deploy/node/reconfigure-node.sh --config /etc/gfc-node/install.env
_self="${BASH_SOURCE[0]:-$0}"
_self="${_self//$'\r'/}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$_DIR" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
changed = False
for p in sorted(d.glob("*.sh")):
    t = p.read_bytes().decode("utf-8", errors="replace")
    f = t.replace("\r\n", "\n").replace("\r", "\n")
    if p.suffix == ".sh":
        f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
    if f != t:
        p.write_text(f, encoding="utf-8", newline="\n")
        changed = True
sys.exit(1 if changed else 0)
PY
  if [[ $? -eq 1 ]]; then
    exec bash "$_DIR/$(basename "$_self")" "$@"
  fi
fi
set -euo pipefail

# shellcheck source=deploy/node/install-config.sh
source "$_DIR/install-config.sh"

CONFIG_FILE=""
FORCE_REAPPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE=${2:-}; shift 2 ;;
    --force-reapply) FORCE_REAPPLY=1; shift ;;
    -h|--help)
      echo "用法: sudo bash reconfigure-node.sh [--config FILE] [--force-reapply]"
      exit 0
      ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "请用 root 执行"; exit 1; }

if [[ -n "$CONFIG_FILE" ]]; then
  gfc_load_install_env_file "$CONFIG_FILE"
elif [[ -f /etc/gfc-node/install.env ]]; then
  echo "==> 从 /etc/gfc-node/install.env 加载，交互可覆盖各项"
  gfc_load_install_env_file /etc/gfc-node/install.env
  if [[ -t 0 ]]; then
    read -r -p "是否交互修改参数？[y/N]: " edit
    if [[ "$edit" =~ ^[Yy]$ ]]; then
      gfc_collect_install_config_interactive
    fi
  fi
else
  gfc_collect_install_config_interactive
fi

gfc_show_install_summary
gfc_validate_install_config || true
gfc_write_install_files

if [[ -f /usr/local/bin/gfc-node-agent-start ]]; then
  install -m 755 "$_DIR/gfc-node-agent-start.sh" /usr/local/bin/gfc-node-agent-start
fi

if [[ $FORCE_REAPPLY -eq 1 ]]; then
  STATE="${GFC_ROOT:-/opt/gfc-node}/node-agent/state/node_state.json"
  if [[ -f "$STATE" ]] && command -v python3 &>/dev/null; then
    python3 - <<PY
import json
from pathlib import Path
p = Path("$STATE")
d = json.loads(p.read_text(encoding="utf-8"))
d.pop("applied_version", None)
p.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
print("==> 已清除 applied_version，下次轮询强制重载配置")
PY
  fi
fi

systemctl daemon-reload
systemctl restart gfc-node-agent
sleep 3
systemctl is-active gfc-node-agent || journalctl -u gfc-node-agent -n 20 --no-pager

echo "==> 重新配置完成"
