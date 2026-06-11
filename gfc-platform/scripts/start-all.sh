#!/bin/bash
# One-click start: API + Web UI + Node Agent
_self="${BASH_SOURCE[0]:-$0}"
if grep -q $'\r' "$_self" 2>/dev/null; then
  sed -i 's/\r$//' "$_self"
  exec bash "$_self" "$@"
fi
set -euo pipefail

ROOT="${GFC_ROOT:-/var/socks}"

_strip_crlf_file() {
  local f=$1
  [[ -f "$f" ]] || return 0
  if grep -q $'\r' "$f" 2>/dev/null; then
    sed -i 's/\r$//' "$f"
  fi
}
API_DIR="${ROOT}/control-plane/api"
WEB_DIR="${ROOT}/web-ui"
AGENT_DIR="${ROOT}/node-agent"
API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8080}"
WEB_HOST="${WEB_HOST:-0.0.0.0}"
WEB_PORT="${WEB_PORT:-5173}"
PID_DIR="${ROOT}/run"
LOG_DIR="${ROOT}/logs"

if [[ -f "${ROOT}/gfc.env" ]]; then
  GFC_ENV_FILE="${ROOT}/gfc.env"
elif [[ -f "${ROOT}/scripts/gfc.env" ]]; then
  GFC_ENV_FILE="${ROOT}/scripts/gfc.env"
else
  GFC_ENV_FILE=""
fi
if [[ -n "$GFC_ENV_FILE" ]]; then
  _strip_crlf_file "$GFC_ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$GFC_ENV_FILE"
  set +a
fi

SERVER_URL="${SERVER_URL:-http://127.0.0.1:${API_PORT}}"
BOOTSTRAP_TOKEN="${BOOTSTRAP_TOKEN:-demo-bootstrap}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
REGION="${REGION:-unknown}"
POLL_SECONDS="${POLL_SECONDS:-10}"
STATE_FILE="${STATE_FILE:-${AGENT_DIR}/state/node_state.json}"
CONFIG_DIR="${CONFIG_DIR:-${AGENT_DIR}/state/dataplane}"

mkdir -p "$PID_DIR" "$LOG_DIR" "$(dirname "$STATE_FILE")" "$CONFIG_DIR"
if [[ $EUID -eq 0 && -f "$ROOT/deploy/scripts/install-logrotate.sh" ]]; then
  bash "$ROOT/deploy/scripts/install-logrotate.sh" control "$LOG_DIR" 2>/dev/null || true
fi

_pids=(gfc-api gfc-web gfc-node)

free_listen_port() {
  local port=$1
  local pids=""
  if command -v ss >/dev/null 2>&1; then
    pids=$(ss -lntp "sport = :${port}" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u) || true
  elif command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -t -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u) || true
  fi
  if [[ -n "$pids" ]]; then
    echo "    Freeing port ${port} (pids: $(echo "$pids" | tr '\n' ' '))"
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in $pids; do
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
}

stop_one() {
  local name=$1
  local f="$PID_DIR/${name}.pid"
  if [[ -f "$f" ]]; then
    local pid
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -P "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  fi
}

stop_all() {
  echo "Stopping GFC services (API + Web + Node Agent)..."
  stop_one gfc-node
  stop_one gfc-web
  stop_one gfc-api
  echo "Stopped."
}

start_api() {
  if [[ ! -d "$API_DIR/.venv" ]]; then
    echo "Creating API venv..."
    python3 -m venv "$API_DIR/.venv"
    "$API_DIR/.venv/bin/pip" install -U pip -q
    "$API_DIR/.venv/bin/pip" install -r "$API_DIR/requirements.txt" -q
  fi
  if [[ -f "$PID_DIR/gfc-api.pid" ]] && kill -0 "$(cat "$PID_DIR/gfc-api.pid")" 2>/dev/null; then
    echo "API already running (pid $(cat "$PID_DIR/gfc-api.pid"))"
    return
  fi
  free_listen_port "$API_PORT"
  echo "Starting API on ${API_HOST}:${API_PORT}..."
  export GFC_BOOTSTRAP_TOKENS="${GFC_BOOTSTRAP_TOKENS:-${BOOTSTRAP_TOKEN:-demo-bootstrap}}"
  cd "$API_DIR"
  nohup .venv/bin/uvicorn app.main:app --host "$API_HOST" --port "$API_PORT" \
    >>"$LOG_DIR/gfc-api.log" 2>&1 &
  echo $! >"$PID_DIR/gfc-api.pid"
  local ok=0
  local i
  for i in $(seq 1 15); do
    if curl -fsS "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  if [[ "$ok" -eq 1 ]]; then
    echo "API OK: http://127.0.0.1:${API_PORT}/healthz"
  else
    echo "ERROR: API failed to start. Check: tail -50 $LOG_DIR/gfc-api.log"
    return 1
  fi
}

start_web() {
  if [[ ! -d "$WEB_DIR/node_modules" ]]; then
    echo "Installing Web UI dependencies (first run, may take a few minutes)..."
    cd "$WEB_DIR"
    if ! npm install --no-audit --no-fund; then
      echo "ERROR: npm install failed. Re-run: cd $WEB_DIR && npm install"
      return 1
    fi
  fi
  if [[ -f "$PID_DIR/gfc-web.pid" ]] && kill -0 "$(cat "$PID_DIR/gfc-web.pid")" 2>/dev/null; then
    echo "Web UI already running (pid $(cat "$PID_DIR/gfc-web.pid"))"
    return
  fi
  free_listen_port "$WEB_PORT"
  echo "Starting Web UI on ${WEB_HOST}:${WEB_PORT}..."
  cd "$WEB_DIR"
  export VITE_API_PROXY_TARGET="http://127.0.0.1:${API_PORT}"
  nohup npm run dev -- --host "$WEB_HOST" --port "$WEB_PORT" --strictPort \
    >>"$LOG_DIR/gfc-web.log" 2>&1 &
  echo $! >"$PID_DIR/gfc-web.pid"
  sleep 4
  if ! ss -lntp 2>/dev/null | grep -q ":${WEB_PORT} "; then
    echo "ERROR: Web UI not listening on ${WEB_PORT}. Check: tail -50 $LOG_DIR/gfc-web.log"
    return 1
  fi
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
  echo "Web UI: http://${ip}:${WEB_PORT}"
}

start_node() {
  if [[ ! -f "$AGENT_DIR/run_agent.py" ]]; then
    echo "ERROR: missing $AGENT_DIR/run_agent.py — sync latest node-agent code"
    return 1
  fi
  if [[ ! -d "$AGENT_DIR/.venv" ]]; then
    echo "Creating Node Agent venv..."
    python3 -m venv "$AGENT_DIR/.venv"
    "$AGENT_DIR/.venv/bin/pip" install -U pip -q
    "$AGENT_DIR/.venv/bin/pip" install -r "$AGENT_DIR/requirements.txt" -q
  fi
  if [[ -f "$PID_DIR/gfc-node.pid" ]]; then
    if kill -0 "$(cat "$PID_DIR/gfc-node.pid")" 2>/dev/null; then
      echo "Node Agent already running (pid $(cat "$PID_DIR/gfc-node.pid"))"
      return
    fi
    rm -f "$PID_DIR/gfc-node.pid"
  fi
  echo "Starting Node Agent -> ${SERVER_URL} (name=${NODE_NAME}, region=${REGION})..."
  cd "$AGENT_DIR"
  nohup "$AGENT_DIR/.venv/bin/python" "$AGENT_DIR/run_agent.py" \
    --server "$SERVER_URL" \
    --bootstrap-token "$BOOTSTRAP_TOKEN" \
    --node-name "$NODE_NAME" \
    --region "$REGION" \
    --state-file "$STATE_FILE" \
    --config-dir "$CONFIG_DIR" \
    --poll-seconds "$POLL_SECONDS" \
    >>"$LOG_DIR/gfc-node.log" 2>&1 &
  echo $! >"$PID_DIR/gfc-node.pid"
  sleep 3
  if kill -0 "$(cat "$PID_DIR/gfc-node.pid")" 2>/dev/null; then
    echo "Node Agent OK (pid $(cat "$PID_DIR/gfc-node.pid"))"
    return
  fi
  echo "ERROR: Node Agent exited. Last log lines:"
  tail -30 "$LOG_DIR/gfc-node.log" 2>/dev/null || true
  rm -f "$PID_DIR/gfc-node.pid"
  return 1
}

status_all() {
  local name
  for name in "${_pids[@]}"; do
    if [[ -f "$PID_DIR/${name}.pid" ]] && kill -0 "$(cat "$PID_DIR/${name}.pid")" 2>/dev/null; then
      echo "${name}: running (pid $(cat "$PID_DIR/${name}.pid"))"
    else
      echo "${name}: stopped"
    fi
  done
}

upgrade_api_deps() {
  echo "==> Upgrading API Python dependencies..."
  if [[ ! -d "$API_DIR/.venv" ]]; then
    python3 -m venv "$API_DIR/.venv"
  fi
  "$API_DIR/.venv/bin/pip" install -U pip -q
  "$API_DIR/.venv/bin/pip" install -r "$API_DIR/requirements.txt" -q
}

upgrade_agent_deps() {
  echo "==> Upgrading Node Agent Python dependencies..."
  if [[ ! -d "$AGENT_DIR/.venv" ]]; then
    python3 -m venv "$AGENT_DIR/.venv"
  fi
  "$AGENT_DIR/.venv/bin/pip" install -U pip -q
  "$AGENT_DIR/.venv/bin/pip" install -r "$AGENT_DIR/requirements.txt" -q
}

upgrade_web_deps() {
  if [[ -d "$WEB_DIR" ]] && command -v npm >/dev/null 2>&1; then
    echo "==> Refreshing Web UI npm dependencies..."
    (cd "$WEB_DIR" && npm install --no-audit --no-fund)
  fi
}

upgrade_deps() {
  upgrade_api_deps
  upgrade_agent_deps
  upgrade_web_deps
  echo "Dependencies upgraded."
}

status_control() {
  local name
  for name in gfc-api gfc-web; do
    if [[ -f "$PID_DIR/${name}.pid" ]] && kill -0 "$(cat "$PID_DIR/${name}.pid")" 2>/dev/null; then
      echo "${name}: running (pid $(cat "$PID_DIR/${name}.pid"))"
    else
      echo "${name}: stopped"
    fi
  done
}

stop_control() {
  echo "Stopping control plane (API + Web)..."
  stop_one gfc-web
  stop_one gfc-api
  free_listen_port "$WEB_PORT"
  free_listen_port "$API_PORT"
}

case "${1:-start}" in
  start)
    start_api || exit 1
    start_web || exit 1
    start_node || exit 1
    echo ""
    echo "Done. Logs: $LOG_DIR"
    status_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    sleep 1
    start_api || exit 1
    start_web || exit 1
    start_node || exit 1
    status_all
    ;;
  status)
    status_all
    ;;
  upgrade)
    upgrade_deps
    stop_all
    sleep 1
    start_api || exit 1
    start_web || exit 1
    start_node || exit 1
    status_all
    ;;
  control-start)
    start_api || exit 1
    start_web || exit 1
    echo ""
    echo "Control plane only (no node agent). Logs: $LOG_DIR"
    status_control
    ;;
  control-stop)
    stop_control
    ;;
  control-restart)
    stop_control
    sleep 1
    start_api || exit 1
    start_web || exit 1
    status_control
    ;;
  control-upgrade)
    upgrade_api_deps
    upgrade_web_deps
    stop_control
    sleep 1
    start_api || exit 1
    start_web || exit 1
    status_control
    ;;
  control-status)
    status_control
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|upgrade|status|control-start|control-stop|control-restart|control-upgrade|control-status}"
    echo "  start / upgrade     All-in-one dev: API + Web + Node Agent on same host"
    echo "  control-*           Control plane only: API + Web (production CP host)"
    exit 1
    ;;
esac
