#!/usr/bin/env bash
# Apply kernel policy routing after gfctun is up (gateway / transparent modes).
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# gfc.env is root-only (600); sing-box Exec*Post uses '+' to run this as root.
# When invoked manually as non-root, skip unreadable env and rely on exported vars.
if [[ -r "$GFC_ENV" ]]; then
  set -a && source "$GFC_ENV" && set +a
fi

# shellcheck source=lib-policy-routing.sh
source "$SCRIPT_DIR/lib-policy-routing.sh"

start() {
  echo "==> gfc-routing start"
  # shellcheck source=lib-gfc-mode.sh
  source "${SCRIPT_DIR}/lib-gfc-mode.sh"
  if gfc_need_proxy_dataplane; then
    refresh_gfc_policy_nft || true
  fi
  if ! apply_policy_routing; then
    echo "    WARN: proxy routing not ready (start sing-box after line code)" >&2
    exit 1
  fi
  if [[ -x "$SCRIPT_DIR/apply-tc-htb.sh" ]]; then
    bash "$SCRIPT_DIR/apply-tc-htb.sh" apply 2>/dev/null || true
  fi
  echo "==> gfc-routing done"
}

stop() {
  echo "==> gfc-routing stop"
  teardown_policy_routing
}

direct() {
  echo "==> gfc-routing direct"
  teardown_gfc_nft_policy 2>/dev/null || true
  teardown_policy_routing 2>/dev/null || true
  if [[ -x "$SCRIPT_DIR/apply-tc-htb.sh" ]]; then
    bash "$SCRIPT_DIR/apply-tc-htb.sh" remove 2>/dev/null || true
  fi
  echo "==> gfc-routing direct done (proxy disabled; re-run start after proxy enable)"
}

case "${1:-start}" in
  start) start ;;
  direct) direct ;;
  stop) stop ;;
  *) echo "usage: $0 {start|direct|stop}"; exit 1 ;;
esac
