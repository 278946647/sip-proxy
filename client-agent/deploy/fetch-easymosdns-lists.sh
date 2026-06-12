#!/usr/bin/env bash
# Import easymosdns rules (same as rules/update) into GFC mosdns tables
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${AGENT_DIR:-$GFC_ROOT/client-agent}"
SRC_ROOT="${SRC_ROOT:-/opt/sip-proxy-src/client-agent}"
[[ -d "$SRC_ROOT/client_agent" ]] && AGENT_DIR="$SRC_ROOT"

export PYTHONPATH="$AGENT_DIR"
PY="${AGENT_DIR}/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

SOURCE="${1:-github}"
case "$SOURCE" in
  github|cdn) ;;
  *)
    echo "Usage: sudo bash fetch-easymosdns-lists.sh [github|cdn]"
    exit 1
    ;;
esac

"$PY" -c "
from client_agent.easymosdns_update import update_easymosdns_rules
import json
r = update_easymosdns_rules('$SOURCE')
print(json.dumps(r, ensure_ascii=False, indent=2))
"
