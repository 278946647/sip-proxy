#!/usr/bin/env bash
# Quick repair: sync client-web + restart :80 / :81 (run from client-agent source tree)
set -euo pipefail
_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"
if [[ -f "$_DIR/../client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
elif [[ -f "$_DIR/client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$_DIR"
else
  echo "ERROR: run from client-agent/deploy/"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run: sudo bash $0"
  exit 1
fi

GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
ENV_FILE=/etc/gfc-client/gfc.env
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

bash "$_DIR/sync-code.sh"

# 若 80 被其他进程占用，提示
if ss -lnt 2>/dev/null | grep ':80 ' | grep -qv python; then
  echo "WARN: port 80 may be taken by another process:"
  ss -lntup | grep ':80 ' || true
fi

_free_port() {
  local port="$1"
  if ! ss -lntup 2>/dev/null | grep -q ":${port} "; then
    return 0
  fi
  local pids
  pids="$(ss -lntup 2>/dev/null | grep ":${port} " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u)"
  for pid in $pids; do
    [[ -n "$pid" ]] || continue
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    if [[ "$comm" == python* ]] || [[ "$comm" == "python3" ]]; then
      echo "    free :${port} — stop stale python pid=$pid"
      kill "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  done
}

systemctl daemon-reload
systemctl enable gfc-client-web 2>/dev/null || true
systemctl unmask gfc-client-flash 2>/dev/null || true
systemctl enable gfc-client-flash 2>/dev/null || true

_free_port 80
_free_port 81

if [[ -f /etc/gfc-client/gfc.env ]]; then
  if grep -q '^GFC_WEB_MODE=admin' /etc/gfc-client/gfc.env; then
    sed -i 's/^GFC_WEB_MODE=admin/GFC_WEB_MODE=both/' /etc/gfc-client/gfc.env
  elif ! grep -q '^GFC_WEB_MODE=' /etc/gfc-client/gfc.env; then
    echo 'GFC_WEB_MODE=both' >>/etc/gfc-client/gfc.env
  fi
  if grep -q '^GFC_CLIENT_HTTPS=' /etc/gfc-client/gfc.env; then
    sed -i 's/^GFC_CLIENT_HTTPS=.*/GFC_CLIENT_HTTPS=0/' /etc/gfc-client/gfc.env
  else
    echo 'GFC_CLIENT_HTTPS=0' >>/etc/gfc-client/gfc.env
  fi
fi

install -m 755 "$CLIENT_ROOT/deploy/gfc-client-flash-start.sh" /usr/local/bin/gfc-client-flash-start 2>/dev/null || true
install -m 755 "$CLIENT_ROOT/deploy/gfc-client-web-start.sh" /usr/local/bin/gfc-client-web-start 2>/dev/null || true

systemctl restart gfc-client-web
systemctl restart gfc-client-flash 2>/dev/null || true

sleep 2
echo ""
echo "==> Port check (both :80 and :81 should be python, single process)"
if ! ss -lntup | grep -qE ':81 '; then
  echo "WARN: :81 not listening — check GFC_WEB_MODE in gfc.env (should use --mode both in gfc-client-web-start)"
  journalctl -u gfc-client-web -n 30 --no-pager 2>/dev/null | tail -15
fi
ss -lntup | grep -E ':80 |:81 ' || echo "WARN: 80/81 still not listening — run: sudo bash deploy/diagnose-web.sh"
echo ""
journalctl -u gfc-client-web -n 20 --no-pager 2>/dev/null || tail -20 /var/log/gfc-client/gfc-client-web.log 2>/dev/null || true
echo "---"
journalctl -u gfc-client-flash -n 20 --no-pager 2>/dev/null || tail -20 /var/log/gfc-client/gfc-client-flash.log 2>/dev/null || true
echo ""
echo "Try: http://192.168.68.1/  and  http://192.168.68.1:81/"
