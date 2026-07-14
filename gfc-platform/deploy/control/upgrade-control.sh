#!/usr/bin/env bash
# Upgrade control plane (API + Web) on a running server — keeps gfc-data volume / DB.
#
# Usage:
#   cd /opt/gfc && sudo bash deploy/control/upgrade-control.sh
set -euo pipefail

ROOT="${GFC_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

# shellcheck source=deploy/control/compose-util.sh
source "$(dirname "$0")/compose-util.sh"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

gfc_compose_cmd

echo "==> sync code from origin/main"
git fetch origin
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  echo "ERROR: origin/main not found"
  exit 1
fi
if [[ "$(git symbolic-ref -q HEAD || true)" != "refs/heads/main" ]]; then
  echo "    checkout main (was detached or other branch)"
  git checkout -B main origin/main
else
  git pull --ff-only origin main
fi

echo "==> build api + web"
"${COMPOSE[@]}" build --no-cache api web

echo "==> safe replace all containers (gfc_compose_safe_up)"
gfc_compose_safe_up "$ROOT" 0
install -m 755 "$ROOT/deploy/control/gfc-compose.sh" /usr/local/bin/gfc-compose 2>/dev/null || true
# Prefer .env port if present (default API port is 8181)
if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a && source "$ROOT/.env" && set +a
fi
API_WAIT_PORT="${GFC_PUBLIC_PORT:-${API_PORT:-8181}}"
gfc_compose_wait_api "$API_WAIT_PORT" 30 || true

echo ""
"${COMPOSE[@]}" ps
echo ""
echo "Web: http://$(hostname -I | awk '{print $1}'):5173"
echo "Verify: curl -fsS http://127.0.0.1:${API_WAIT_PORT}/healthz"
