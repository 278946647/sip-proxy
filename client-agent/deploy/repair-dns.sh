#!/usr/bin/env bash
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export GFC_ETC=/etc/gfc-client
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

bash "$_DIR/sync-code.sh"

echo "==> mosdns-x (easymosdns requires mosdns-x, not v5)"
bash "$_DIR/upgrade-mosdns-x.sh" || echo "WARN: mosdns-x upgrade skipped"
bash "$_DIR/fix-mosdns-unit.sh"

systemctl stop gfc-client-agent 2>/dev/null || true

echo "==> Bootstrap / reapply dataplane"
cd "$AGENT_DIR"
PYTHONPATH="$AGENT_DIR" "$PY" -c "
from client_agent.bootstrap import ensure_bootstrap_dataplane, ensure_services_running
ok, msg = ensure_bootstrap_dataplane(try_download=True)
print(msg)
if not ok:
    raise SystemExit(1)
ensure_services_running()
"

if [[ -f /etc/gfc-client/sing-box.json ]]; then
  sing-box check -c /etc/gfc-client/sing-box.json
fi

systemctl is-active gfc-mosdns gfc-client-sing-box gfc-client-web gfc-client-flash 2>/dev/null || true
echo "Done."
