#!/usr/bin/env bash
# Verify bootstrap token alignment and (optionally) control plane reachability.
sed -i 's/\r$//' "$0" 2>/dev/null || true
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="${API:-${SERVER_URL:-http://127.0.0.1:8080}}"
BOOTSTRAP="${BOOTSTRAP:-${BOOTSTRAP_TOKEN:-demo-bootstrap}}"

echo "==> GFC prerequisite check"
echo "    Repo: $ROOT"
echo "    API:  $API"
echo "    Bootstrap token (node): $BOOTSTRAP"

EXPECTED="demo-bootstrap"
for f in \
  "$ROOT/docker-compose.yml" \
  "$ROOT/scripts/gfc.env.example" \
  "$ROOT/deploy/node/node.env.example" \
  "$ROOT/deploy/node/install-ubuntu.sh"; do
  if [[ -f "$f" ]] && grep -q "demo-bootstrap" "$f" 2>/dev/null; then
    echo "    OK default token in $(basename "$f")"
  fi
done

if [[ "$BOOTSTRAP" != "$EXPECTED" ]]; then
  echo "WARN: node BOOTSTRAP_TOKEN=$BOOTSTRAP differs from repo default $EXPECTED"
  echo "      Ensure control plane GFC_BOOTSTRAP_TOKENS includes: $BOOTSTRAP"
fi

if command -v curl >/dev/null 2>&1; then
  echo "==> API healthz"
  if curl -fsS --connect-timeout 5 "$API/healthz" >/dev/null; then
    echo "    OK $API is reachable"
    echo "==> bootstrap-check (does not register a node)"
    CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$API/nodes/bootstrap-check" \
      -H 'Content-Type: application/json' \
      -d "{\"bootstrap_token\":\"$BOOTSTRAP\",\"node_name\":\"prereq-probe\",\"region\":\"test\"}" || echo "000")
    if [[ "$CODE" == "200" ]]; then
      echo "    OK bootstrap token accepted by API"
    elif [[ "$CODE" == "403" ]]; then
      echo "    FAIL invalid bootstrap token (403) — fix GFC_BOOTSTRAP_TOKENS on API or BOOTSTRAP_TOKEN on node"
      exit 1
    else
      echo "    WARN activate returned HTTP $CODE (API up but activate failed)"
    fi
  else
    echo "    SKIP API not reachable at $API (start control plane first)"
    echo "         docker compose up -d   OR   scripts/start-all.sh start"
    if [[ "${REQUIRE_API:-0}" == "1" ]]; then
      echo "    FAIL REQUIRE_API=1 but API is down"
      exit 1
    fi
  fi
else
  echo "    SKIP curl not installed"
fi

echo "==> Prerequisite check done"
