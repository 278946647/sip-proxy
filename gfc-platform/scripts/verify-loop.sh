#!/usr/bin/env bash
# End-to-end smoke test against a running control plane API.
set -euo pipefail

API="${API:-http://127.0.0.1:8080}"
BOOTSTRAP="${BOOTSTRAP:-demo-bootstrap}"

echo "== healthz =="
curl -fsS "$API/healthz"
echo

echo "== activate node =="
ACTIVATE=$(curl -fsS -X POST "$API/nodes/activate" \
  -H 'Content-Type: application/json' \
  -d "{\"bootstrap_token\":\"$BOOTSTRAP\",\"node_name\":\"verify-node\",\"region\":\"test\"}")
echo "$ACTIVATE"
NODE_ID=$(echo "$ACTIVATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['node_id'])")
TOKEN=$(echo "$ACTIVATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['node_token'])")

echo "== create socks =="
SOCKS=$(curl -fsS -X POST "$API/admin/socks" \
  -H 'Content-Type: application/json' \
  -d '{"name":"verify-socks","host":"127.0.0.1","port":1080,"username":null,"password":null}')
echo "$SOCKS"
SOCKS_ID=$(echo "$SOCKS" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "== create line =="
LINE=$(curl -fsS -X POST "$API/admin/lines" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"verify-line\",\"source_cidrs\":[\"10.0.0.0/24\"],\"node_id\":$NODE_ID,\"socks_profile_id\":$SOCKS_ID}")
echo "$LINE"

echo "== pull config (as node) =="
curl -fsS "$API/nodes/me/config" -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

echo "== list nodes =="
curl -fsS "$API/admin/nodes" | python3 -m json.tool

echo
echo "OK: control plane loop verified. Start node-agent with the token above for continuous poll."
