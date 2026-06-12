#!/usr/bin/env bash
# Write Base32 line code, activate with control plane, apply dataplane config
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

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
# Ensure public DNS if resolver is broken (activate uses IP; git/curl may not)
if ! getent hosts github.com >/dev/null 2>&1; then
  bash "$_DIR/bootstrap-dns.sh" || true
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${AGENT_DIR:-$GFC_ROOT/client-agent}"

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
import json, sys, traceback
from client_agent.web_actions import flash_line_code
from client_agent.activate_now import activate_and_apply

result = flash_line_code(sys.argv[1], reset_state=True, restart_agent=False)
print(json.dumps(result, ensure_ascii=False, indent=2))
try:
    act = activate_and_apply()
    print('activate:', json.dumps(act, ensure_ascii=False, indent=2))
    if not act.get('ok'):
        raise SystemExit(1)
    if act.get('ack_warning'):
        print('WARN: ack deferred (config applied locally):', act['ack_warning'])
except Exception as exc:
    print('activate FAILED:', exc)
    traceback.print_exc()
    raise SystemExit(1)
" "$CODE"

echo "==> Restart agent (heartbeat loop)"
systemctl restart gfc-client-agent

echo ""
STATE="${STATE_FILE:-/opt/gfc-client/client-agent/state/client_state.json}"
if [[ -f "$STATE" ]]; then
  echo "state: $STATE"
  cat "$STATE"
else
  echo "WARN: state missing"
fi

if [[ -f /etc/gfc-client/dataplane-mode.json ]]; then
  echo "dataplane:"
  cat /etc/gfc-client/dataplane-mode.json
fi

if [[ -f /etc/gfc-client/sing-box.json ]]; then
  sing-box check -c /etc/gfc-client/sing-box.json && echo "sing-box: ok"
  if grep -q gfc0 /etc/gfc-client/sing-box.json 2>/dev/null; then
    echo "sing-box: active (gfc0 tun present)"
  else
    echo "WARN: sing-box still idle (no gfc0)"
  fi
fi

systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-agent gfc-client-web 2>/dev/null || true
