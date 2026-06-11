#!/usr/bin/env bash
set -euo pipefail

ROOT="${GFC_ROOT:-/var/socks}"
if [[ -f "${ROOT}/gfc.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ROOT}/gfc.env"
  set +a
fi

SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
REGION="${REGION:-unknown}"
STATE_FILE="${STATE_FILE:-${ROOT}/node-agent/state/node_state.json}"
CONFIG_DIR="${CONFIG_DIR:-${ROOT}/node-agent/state/dataplane}"
POLL_SECONDS="${POLL_SECONDS:-10}"

cd "${ROOT}/node-agent"
source .venv/bin/activate

exec python run_agent.py \
  --server "$SERVER_URL" \
  --bootstrap-token "$BOOTSTRAP_TOKEN" \
  --node-name "$NODE_NAME" \
  --region "$REGION" \
  --state-file "$STATE_FILE" \
  --config-dir "$CONFIG_DIR" \
  --poll-seconds "$POLL_SECONDS"
