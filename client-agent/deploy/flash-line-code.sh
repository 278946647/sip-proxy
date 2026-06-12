#!/usr/bin/env bash
# Write Base32 line code and restart agent (full validation via Python)
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash flash-line-code.sh LINE_CODE_FILE_OR_STRING"
  echo "       sudo bash flash-line-code.sh --file /media/usb/line.b32"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 ..."
  exit 1
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
SRC_ROOT="${SRC_ROOT:-/opt/sip-proxy-src/client-agent}"
AGENT_DIR="${AGENT_DIR:-$GFC_ROOT/client-agent}"
[[ -d "$SRC_ROOT/client_agent" ]] && AGENT_DIR="$SRC_ROOT"

export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

CODE=""
if [[ "$1" == "--file" ]]; then
  CODE="$(cat "${2:?missing file path}")"
elif [[ -f "$1" ]]; then
  CODE="$(cat "$1")"
else
  CODE="$1"
fi

echo "==> Flash line code"
"$PY" -c "
import json, sys
from client_agent.web_actions import flash_line_code
from client_agent.bootstrap import ensure_bootstrap_dataplane, ensure_services_running

result = flash_line_code(sys.argv[1], reset_state=True)
print(json.dumps(result, ensure_ascii=False, indent=2))
ok, msg = ensure_bootstrap_dataplane(try_download=False)
print('bootstrap:', msg)
ensure_services_running()
" "$CODE"

echo "==> Restart agent (activate + pull config)"
systemctl restart gfc-client-agent

echo ""
echo "等待 15s 后检查激活状态..."
sleep 15
STATE="${STATE_FILE:-/opt/gfc-client/client-agent/state/client_state.json}"
if [[ -f "$STATE" ]]; then
  echo "state: $STATE"
  cat "$STATE"
else
  echo "WARN: state 文件尚未生成，请检查 agent 日志:"
  echo "  journalctl -u gfc-client-agent -n 30 --no-pager"
fi

if [[ -f /etc/gfc-client/sing-box.json ]]; then
  sing-box check -c /etc/gfc-client/sing-box.json && echo "sing-box: ok"
fi
systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-agent gfc-client-web 2>/dev/null || true
