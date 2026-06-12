#!/usr/bin/env bash
# GFC client Web — admin :80 + flash :81 (single process)
set -euo pipefail
ENV_FILE="${ENV_FILE:-/etc/gfc-client/gfc.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
AGENT_DIR="${GFC_ROOT}/client-agent"
VENV="${AGENT_DIR}/.venv/bin/python"
WEB_ROOT="${GFC_CLIENT_WEB_ROOT:-${GFC_ROOT}/client-web}"

if [[ ! -x "$VENV" ]]; then
  echo "ERROR: missing venv $VENV — run: sudo bash deploy/install.sh" >&2
  exit 1
fi
if [[ ! -f "${AGENT_DIR}/client_agent/web_server.py" ]]; then
  echo "ERROR: missing ${AGENT_DIR}/client_agent — run: sudo bash deploy/repair-web.sh" >&2
  exit 1
fi

mkdir -p "$WEB_ROOT"
cd "$AGENT_DIR"
export PYTHONPATH="${AGENT_DIR}${PYTHONPATH:+:$PYTHONPATH}"
exec "$VENV" -m client_agent.web_server --mode both --root "$WEB_ROOT"
