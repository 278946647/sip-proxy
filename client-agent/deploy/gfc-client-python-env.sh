# Shared Python env for gfc-client systemd wrappers (source only).
# shellcheck shell=bash

gfc_client_load_env() {
  ENV_FILE="${ENV_FILE:-/etc/gfc-client/gfc.env}"
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
  export GFC_ROOT
  export PYTHONPATH="${GFC_ROOT}/client-agent${PYTHONPATH:+:$PYTHONPATH}"
  VENV="${GFC_ROOT}/client-agent/.venv/bin/python"
  if [[ ! -x "$VENV" ]]; then
    echo "ERROR: Python venv missing: $VENV (re-run install.sh)" >&2
    exit 1
  fi
  if [[ ! -f "${GFC_ROOT}/client-agent/client_agent/web_server.py" ]]; then
    echo "ERROR: client_agent package missing under ${GFC_ROOT}/client-agent" >&2
    exit 1
  fi
  cd "${GFC_ROOT}/client-agent"
}
