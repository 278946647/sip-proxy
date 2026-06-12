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

echo "==> Sync client-agent -> $GFC_ROOT"
rsync -a "$CLIENT_ROOT/client_agent/" "$GFC_ROOT/client-agent/client_agent/"
cp -f "$CLIENT_ROOT/setup.py" "$CLIENT_ROOT/requirements.txt" "$GFC_ROOT/client-agent/" 2>/dev/null || true
rsync -a "$CLIENT_ROOT/deploy/"*.sh /usr/local/bin/
chmod +x /usr/local/bin/gfc-client-*.sh

if [[ -d "$CLIENT_ROOT/client-web" ]]; then
  echo "==> Sync client-web"
  rsync -a "$CLIENT_ROOT/client-web/" "$GFC_ROOT/client-web/"
else
  echo "WARN: $CLIENT_ROOT/client-web missing"
fi

if [[ -x "$GFC_ROOT/client-agent/.venv/bin/pip" ]]; then
  "$GFC_ROOT/client-agent/.venv/bin/pip" install -q -U pip setuptools wheel
  "$GFC_ROOT/client-agent/.venv/bin/pip" install -q -r "$CLIENT_ROOT/requirements.txt"
  "$GFC_ROOT/client-agent/.venv/bin/pip" install -q -e "$GFC_ROOT/client-agent"
fi

# 若 80 被其他进程占用，提示
if ss -lnt 2>/dev/null | grep ':80 ' | grep -qv python; then
  echo "WARN: port 80 may be taken by another process:"
  ss -lntup | grep ':80 ' || true
fi

systemctl daemon-reload
systemctl enable gfc-client-web 2>/dev/null || true
systemctl stop gfc-client-flash 2>/dev/null || true
systemctl disable gfc-client-flash 2>/dev/null || true
systemctl restart gfc-client-web

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
