#!/usr/bin/env bash
# systemd ExecStart wrapper — reads /etc/gfc-node/gfc.env (no hardcoded URL in unit file).
set -euo pipefail

GFC_ENV=/etc/gfc-node/gfc.env
if [[ -f "$GFC_ENV" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$GFC_ENV"
  set +a
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
POLL_SECONDS="${POLL_SECONDS:-10}"
STATE_FILE="${STATE_FILE:-$GFC_ROOT/node-agent/state/node_state.json}"
CONFIG_DIR="${CONFIG_DIR:-$GFC_ROOT/node-agent/state/dataplane}"
PY="$GFC_ROOT/node-agent/.venv/bin/python"
AGENT="$GFC_ROOT/node-agent/run_agent.py"

for v in SERVER_URL BOOTSTRAP_TOKEN NODE_NAME REGION; do
  if [[ -z "${!v:-}" ]]; then
    echo "gfc-node-agent-start: missing $v in $GFC_ENV" >&2
    exit 1
  fi
done

# TPROXY reply path (lost on reboot; ensure before agent loop).
if [[ -n "${GFC_TPROXY_IFACE:-}" ]] && command -v ip >/dev/null 2>&1; then
  if ! ip rule show 2>/dev/null | grep -q 'fwmark 0x1.*lookup 100'; then
    ip rule add fwmark 0x1 lookup 100 2>/dev/null || true
  fi
  if ! ip route show table 100 2>/dev/null | grep -q 'local'; then
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
  fi
fi

exec "$PY" "$AGENT" \
  --server "$SERVER_URL" \
  --bootstrap-token "$BOOTSTRAP_TOKEN" \
  --node-name "$NODE_NAME" \
  --region "$REGION" \
  --state-file "$STATE_FILE" \
  --config-dir "$CONFIG_DIR" \
  --poll-seconds "$POLL_SECONDS"
