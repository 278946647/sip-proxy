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
  refresh_gfc_policy_nft || true
  apply_policy_routing
  echo "==> gfc-routing done"
}

stop() {
  echo "==> gfc-routing stop"
  teardown_policy_routing
}

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 {start|stop}"; exit 1 ;;
esac
