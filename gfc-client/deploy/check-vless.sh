#!/usr/bin/env bash
# Verify VLESS Reality reachability and sing-box proxy health.
set -euo pipefail

GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -r "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

CFG="/etc/gfc-client/sing-box.json"
if [[ -f /etc/openwrt_release || "${GFC_PLATFORM:-}" == "immortalwrt" || "${GFC_PLATFORM:-}" == "openwrt" ]]; then
  case "${GFC_LIB:-}" in
    ""|/var/lib/gfc-client|/tmp/lib/gfc-client) GFC_LIB=/etc/gfc-client/lib ;;
  esac
fi
BUNDLE="${GFC_LIB:-/var/lib/gfc-client}/state/config_bundle.json"
LOG="/var/log/gfc-client/sing-box.log"
CLASH_API="${GFC_CLASH_API:-127.0.0.1:9090}"

fail=0
ok() { echo "OK  $*"; }
bad() { echo "FAIL $*"; fail=1; }
info() { echo "    $*"; }

echo "==> GFC VLESS / relay node check"
echo

echo "--- sing-box service ---"
if systemctl is-active --quiet gfc-sing-box 2>/dev/null; then
  ok "gfc-sing-box active"
  ps -o user=,pid= -C sing-box 2>/dev/null | head -1 | info
else
  bad "gfc-sing-box not active"
fi
echo

echo "--- VLESS outbound (from sing-box.json) ---"
if [[ ! -f "$CFG" ]]; then
  bad "missing $CFG"
else
  eval "$(python3 - <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
ob = next((o for o in cfg.get("outbounds", []) if o.get("type") == "vless"), {})
print(f'NODE="{ob.get("server", "")}"')
print(f'PORT="{ob.get("server_port", 443)}"')
print(f'UUID="{ob.get("uuid", "")}"')
print(f'FLOW="{ob.get("flow", "")}"')
tls = ob.get("tls") or {}
print(f'SNI="{tls.get("server_name", "")}"')
r = (tls.get("reality") or {})
print(f'PBK="{r.get("public_key", "")}"')
print(f'SID="{r.get("short_id", "")}"')
PY
"$CFG")"
  info "node=${NODE:-?}:${PORT:-443} uuid=${UUID:0:8}... flow=${FLOW:-?}"
  info "reality sni=${SNI:-?} short_id=${SID:-?}"
  WAN="$(python3 - <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
print(cfg.get("route", {}).get("default_interface", ""))
PY
"$CFG")"
  BIND="$(python3 - <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
ob = next((o for o in cfg.get("outbounds", []) if o.get("type") == "vless"), {})
print(ob.get("bind_interface", ""))
PY
"$CFG")"
  info "route.default_interface=${WAN:-<missing>}"
  info "vless.bind_interface=${BIND:-<missing>}"
  [[ -n "${WAN:-}" ]] || bad "sing-box route.default_interface missing — set GFC_WAN_IFACE=ens160 and gfc-bootstrap --reapply"
  [[ -n "${BIND:-}" ]] || bad "VLESS bind_interface missing — reapply after GFC_WAN_IFACE set"
  [[ -n "${NODE:-}" ]] || bad "VLESS server address empty"
  [[ -n "${UUID:-}" ]] || bad "VLESS uuid empty"
  [[ -n "${PBK:-}" ]] || bad "REALITY public_key empty"
  if sing-box check -c "$CFG" >/dev/null 2>&1; then
    ok "sing-box check"
  else
    bad "sing-box check: $(sing-box check -c "$CFG" 2>&1 | tail -1)"
  fi
fi
echo

echo "--- TCP to relay node (WAN path, must NOT go gfctun) ---"
if [[ -n "${NODE:-}" ]]; then
  if timeout 6 bash -c "echo >/dev/tcp/${NODE}/${PORT:-443}" 2>/dev/null; then
    ok "TCP ${NODE}:${PORT:-443} reachable"
  else
    bad "TCP ${NODE}:${PORT:-443} unreachable (firewall / wrong IP / node down)"
  fi
  info "route (main): $(ip -4 route get "${NODE}" 2>/dev/null | tr -s ' ')"
  if ip -4 route get "${NODE}" 2>/dev/null | grep -q 'dev gfctun'; then
    bad "relay node routes via gfctun — add to nft bypass_ip"
  else
    ok "relay node not via gfctun"
  fi
  if id singbox &>/dev/null; then
    info "route (singbox uid): $(sudo -u singbox ip -4 route get "${NODE}" 2>/dev/null | tr -s ' ' || echo n/a)"
  fi
fi
echo

echo "--- nft bypass (relay node must be listed) ---"
BYPASS_FILE="/etc/gfc-client/nftables-policy.conf"
if [[ -f "$BYPASS_FILE" ]]; then
  info "bypass (inline set in policy conf):"
  grep -A2 'set bypass_ip' "$BYPASS_FILE" | sed 's/^/      /' || true
  if [[ -n "${NODE:-}" ]] && grep -qF "${NODE}" "$BYPASS_FILE" 2>/dev/null; then
    ok "relay ${NODE} in bypass set"
  elif [[ -n "${NODE:-}" ]]; then
    bad "relay ${NODE} NOT in nft bypass — VLESS handshake may loop into TUN"
    info "fix: sudo bash deploy/apply-network.sh  (or GFC_NODE_BYPASS=${NODE})"
  fi
else
  bad "missing $BYPASS_FILE — run apply-network.sh"
fi
echo

echo "--- Clash API proxy delay (best VLESS end-to-end test) ---"
if curl -fsS --connect-timeout 2 "http://${CLASH_API}/" >/dev/null 2>&1; then
  PROXY_TAG="proxy"
  if python3 -c "import json; json.load(open('$CFG'))" 2>/dev/null; then
    PROXY_TAG="$(python3 -c "import json; o=json.load(open('$CFG')); print(o.get('route',{}).get('final','proxy'))")"
  fi
  DELAY_URL="http://${CLASH_API}/proxies/${PROXY_TAG}/delay?timeout=10000&url=http://www.gstatic.com/generate_204"
  info "GET $DELAY_URL"
  RESP="$(curl -fsS --connect-timeout 12 "$DELAY_URL" 2>/dev/null || true)"
  if [[ -n "$RESP" ]]; then
    info "response: $RESP"
    if echo "$RESP" | grep -qE '"delay":[0-9]+'; then
      ok "VLESS outbound alive (delay ms in response)"
    else
      bad "VLESS delay test failed: $RESP"
    fi
  else
    bad "Clash API delay request failed (sing-box not in active mode?)"
  fi
else
  bad "Clash API http://${CLASH_API}/ not reachable (idle config or sing-box down)"
  info "activate line code + reapply, then retry"
fi
echo

echo "--- recent sing-box errors ---"
if [[ -f "$LOG" ]]; then
  ERRS="$(grep -iE 'error|reality|vless|refused|timeout|handshake|missing default' "$LOG" 2>/dev/null | tail -15 || true)"
  if [[ -n "$ERRS" ]]; then
    echo "$ERRS" | sed 's/^/    /'
  else
    info "(no recent error lines — good, or log level too quiet)"
  fi
  info "tip: GFC_SINGBOX_LOG_LEVEL=warn in gfc.env + restart for more detail"
else
  info "no log at $LOG"
fi
echo

echo "--- egress via TUN path (foreign IP should use table 2022) ---"
info "route 1.1.1.1: $(ip -4 route get 1.1.1.1 2>/dev/null | tr -s ' ')"
info "route 223.5.5.5: $(ip -4 route get 223.5.5.5 2>/dev/null | tr -s ' ')"
echo

if [[ "$fail" -eq 0 ]]; then
  echo "==> VLESS check passed"
else
  echo "==> VLESS check FAILED — fix items above before tuning split rules"
fi
exit "$fail"
