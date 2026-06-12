#!/usr/bin/env bash
# Diagnose client box: network, web :80/:81, agent
set -uo pipefail

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
[[ -f /etc/gfc-client/gfc.env ]] && source /etc/gfc-client/gfc.env

echo "======== GFC Client Doctor ========"
echo "GFC_ROOT=$GFC_ROOT"
echo ""

echo "--- Network ---"
ip -br addr show | grep -v '^lo'
echo ""
if [[ -f /etc/gfc-client/network-roles.json ]]; then
  cat /etc/gfc-client/network-roles.json
  echo ""
fi

echo "--- Listening TCP (80/81/53) ---"
ss -lntup 2>/dev/null | grep -E ':80 |:81 |:53 |:8787 ' || echo "(none on 80/81/53/8787)"
echo ""

echo "--- systemd ---"
for u in gfc-client-web gfc-client-flash gfc-client-agent gfc-mosdns gfc-client-sing-box dnsmasq; do
  if systemctl list-unit-files "${u}.service" &>/dev/null; then
    printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo '?')"
  fi
done
echo ""

echo "--- Files ---"
for f in \
  "$GFC_ROOT/client-web/index.html" \
  "$GFC_ROOT/client-web/flash.html" \
  "$GFC_ROOT/client-agent/client_agent/web_server.py" \
  "$GFC_ROOT/client-agent/.venv/bin/python" \
  /usr/local/bin/gfc-client-web-start \
  /etc/gfc-client/gfc.env; do
  if [[ -e "$f" ]]; then echo "  OK $f"; else echo "  MISSING $f"; fi
done
echo ""

echo "--- Web test (local) ---"
for port in 80 81; do
  if curl -fsS --connect-timeout 2 "http://127.0.0.1:${port}/" -o /dev/null 2>/dev/null; then
    echo "  OK http://127.0.0.1:${port}/"
  else
    echo "  FAIL http://127.0.0.1:${port}/"
  fi
done
echo ""

echo "--- mosdns / sing-box ---"
for f in /etc/gfc-client/mosdns.yaml /etc/gfc-client/sing-box.json; do
  [[ -f "$f" ]] && echo "  OK $f" || echo "  MISSING $f"
done
for f in /etc/gfc-client/mosdns/block.txt /etc/gfc-client/mosdns/china.txt /etc/gfc-client/mosdns/global.txt; do
  [[ -f "$f" ]] && echo "  OK $f ($(wc -l <"$f") lines)" || echo "  MISSING $f"
done
if command -v mosdns >/dev/null 2>&1 && [[ -f /etc/gfc-client/mosdns.yaml ]]; then
  rc=0
  timeout 2 mosdns start -c /etc/gfc-client/mosdns.yaml >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 124 || "$rc" -eq 0 ]]; then
    echo "  mosdns config: OK"
  else
    echo "  mosdns config: FAIL (exit $rc) — run: sudo bash deploy/repair-dns.sh"
    tail -5 /var/log/gfc-client/mosdns.log 2>/dev/null || true
  fi
fi
echo ""

echo "--- Recent web logs ---"
tail -8 /var/log/gfc-client/gfc-client-web.log 2>/dev/null || journalctl -u gfc-client-web -n 8 --no-pager 2>/dev/null || true
echo "---"
tail -8 /var/log/gfc-client/gfc-client-flash.log 2>/dev/null || journalctl -u gfc-client-flash -n 8 --no-pager 2>/dev/null || true
