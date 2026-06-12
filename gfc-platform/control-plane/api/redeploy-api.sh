#!/usr/bin/env bash
# Safe API redeploy from any cwd — avoids docker-compose 1.29 ContainerConfig bug.
set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$_HERE/../.." && pwd)"
COMPOSE_WRAPPER="$ROOT/deploy/control/gfc-compose.sh"

if [[ ! -f "$COMPOSE_WRAPPER" ]]; then
  echo "ERROR: missing $COMPOSE_WRAPPER"
  exit 1
fi

echo "==> GFC API redeploy (repo: $ROOT)"
cd "$ROOT"
bash "$COMPOSE_WRAPPER" build api
bash "$COMPOSE_WRAPPER" up -d api

echo "==> Wait for API"
for i in $(seq 1 20); do
  if curl -fsS --connect-timeout 2 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    echo "    OK /health"
    curl -s http://127.0.0.1:8080/health
    echo ""
    exit 0
  fi
  sleep 2
done

echo "WARN: API not ready — check: gfc-compose logs --tail=50 api"
exit 1
