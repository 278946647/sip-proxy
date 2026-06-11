#!/usr/bin/env bash
# Verify node agent activation, heartbeat visibility, and config bundle on disk.
_self="${BASH_SOURCE[0]:-$0}"
python3 - "$_self" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_bytes().decode("utf-8", errors="replace")
f = t.replace("\r\n", "\n").replace("\r", "\n")
if p.suffix == ".sh":
    f = f.replace("pipefail" + "STATE=", "pipefail\nSTATE=")
if f != t:
    p.write_text(f, encoding="utf-8", newline="\n")
    sys.exit(1)
sys.exit(0)
PY
if [[ $? -eq 1 ]]; then exec bash "$_self" "$@"; fi
set -euo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-node}"
if [[ -f /etc/gfc-node/gfc.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/gfc-node/gfc.env
  set +a
fi
API="${API:-${SERVER_URL:-http://127.0.0.1:8080}}"
NODE_NAME="${NODE_NAME:-}"
STATE_FILE="${STATE_FILE:-$GFC_ROOT/node-agent/state/node_state.json}"
BUNDLE="${CONFIG_DIR:-$GFC_ROOT/node-agent/state/dataplane}/config_bundle.json"

echo "==> GFC forward node verification"

if systemctl is-active --quiet gfc-node-agent 2>/dev/null; then
  echo "    OK gfc-node-agent is active"
  systemctl --no-pager status gfc-node-agent | head -5 || true
else
  echo "    WARN gfc-node-agent not active (manual run?)"
fi

if systemctl is-enabled --quiet gfc-sing-box 2>/dev/null; then
  if systemctl is-active --quiet gfc-sing-box 2>/dev/null; then
    echo "    OK gfc-sing-box is active"
  else
    echo "    WARN gfc-sing-box enabled but not active (config may not be rendered yet)"
  fi
fi

if [[ ! -f "$STATE_FILE" ]]; then
  echo "    Waiting for activation (up to 30s)..."
  for _ in 1 2 3 4 5 6; do
    sleep 5
    [[ -f "$STATE_FILE" ]] && break
  done
fi
if [[ -f "$STATE_FILE" ]]; then
  echo "    OK state file: $STATE_FILE"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json; d=json.load(open('$STATE_FILE')); print('       node_id:', d.get('node_id')); print('       has token:', bool(d.get('node_token')))"
  fi
else
  echo "    FAIL missing $STATE_FILE — agent may not have activated"
  echo "    Hint: journalctl -u gfc-node-agent -n 50 --no-pager"
  echo "          grep ExecStart /etc/systemd/system/gfc-node-agent.service"
  exit 1
fi

if [[ -f "$BUNDLE" ]]; then
  echo "    OK config bundle: $BUNDLE"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
b=json.load(open('$BUNDLE'))
rules=(b.get('dataplane') or {}).get('rules') or b.get('rules') or []
routes=b.get('staticRoutes') or []
print('       rules:', len(rules))
print('       staticRoutes:', len(routes), routes[:3])
for i,r in enumerate(rules[:3]):
    print('       ', i, 'cidrs=', r.get('sourceCidrs'), 'socks=', (r.get('socks') or {}).get('host'))
"
  fi
else
  echo "    WARN no $BUNDLE yet — add SOCKS + line in Web UI, wait POLL_SECONDS or restart gfc-node-agent"
fi

if [[ -f /etc/gfc-node/sing-box.json ]]; then
  echo "    OK /etc/gfc-node/sing-box.json present"
  if command -v sing-box >/dev/null 2>&1; then
    echo "    sing-box: $(sing-box version 2>/dev/null | head -1 || echo unknown)"
    if sing-box check -c /etc/gfc-node/sing-box.json >/dev/null 2>&1; then
      echo "    OK sing-box check"
    else
      echo "    WARN sing-box check failed — run: sudo bash deploy/node/reinstall-singbox.sh"
      sing-box check -c /etc/gfc-node/sing-box.json 2>&1 | tail -3 || true
    fi
  fi
fi

if [[ -f /etc/gfc-node/static-routes.json ]]; then
  echo "    OK static routes file: /etc/gfc-node/static-routes.json"
  cat /etc/gfc-node/static-routes.json | head -20
  echo "    ip route (grep gfc/custom):"
  ip route show | head -30
fi

SNAT_IF=$(grep -E '^GFC_SNAT_IFACE=' /etc/gfc-node/gfc.env 2>/dev/null | cut -d= -f2- || echo auto)
if [[ "$SNAT_IF" == "auto" ]]; then
  SNAT_IF=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
fi
if [[ -n "$SNAT_IF" && "$SNAT_IF" != "0" && "$SNAT_IF" != "off" ]]; then
  if nft list table ip gfc-nat 2>/dev/null | grep -q "oifname \"${SNAT_IF}\""; then
    echo "    OK egress SNAT masquerade on ${SNAT_IF}"
  else
    echo "    WARN missing SNAT on ${SNAT_IF} — sudo systemctl restart gfc-node-agent"
  fi
fi

if ip rule list 2>/dev/null | grep -q 'fwmark 0x1.*lookup 100'; then
  echo "    OK TPROXY policy: fwmark 0x1 lookup 100"
else
  echo "    FAIL missing TPROXY policy (ip rule fwmark 0x1 lookup 100)"
  echo "         fix: sudo ip rule add fwmark 0x1 lookup 100"
  echo "              sudo ip route replace local 0.0.0.0/0 dev lo table 100"
  echo "         or:  sudo bash deploy/node/force-reapply.sh"
fi

echo "    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
echo "    tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  echo "==> Control plane node list"
  TMP_NODES=$(mktemp)
  if curl -fsS "$API/admin/nodes" -o "$TMP_NODES" 2>/dev/null; then
    if [[ -n "$NODE_NAME" ]]; then
      python3 <<PY
import json, sys
nodes = json.load(open("$TMP_NODES"))
name = "$NODE_NAME"
for n in nodes:
    if n.get("name") == name:
        print("    OK node in API:", name, "online=", n.get("online"), "lastSeenAt=", n.get("lastSeenAt"))
        sys.exit(0)
print("    WARN node", name, "not in admin list yet — wait for heartbeat or check NODE_NAME")
PY
    else
      python3 -m json.tool "$TMP_NODES" | head -40
    fi
  else
    echo "    WARN could not fetch $API/admin/nodes"
  fi
  rm -f "$TMP_NODES"
fi

echo "==> Verification done"
