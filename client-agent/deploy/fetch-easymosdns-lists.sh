#!/usr/bin/env bash
# easymosdns rules/update — github or cdn (curl + bootstrap DNS)
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

SOURCE="${1:-cdn}"
case "$SOURCE" in
  github|cdn) ;;
  *)
    echo "Usage: sudo bash fetch-easymosdns-lists.sh [github|cdn]"
    exit 1
    ;;
esac

systemctl stop gfc-client-agent 2>/dev/null || true

"$PY" -c "
from client_agent.easymosdns_update import update_easymosdns_rules
import json
r = update_easymosdns_rules('$SOURCE')
print(json.dumps(r, ensure_ascii=False, indent=2))
if not r.get('ok'):
    raise SystemExit(1)
"

systemctl start gfc-client-agent 2>/dev/null || true
