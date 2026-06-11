#!/usr/bin/env bash
# Tail / search GFC service logs (control plane or forward node).
set -euo pipefail

CP_LOG_DIR="${GFC_CP_LOG_DIR:-/var/socks/logs}"
FN_LOG_DIR="${GFC_FN_LOG_DIR:-/var/log/gfc-node}"
LINES=80
FOLLOW=0
GREP_PATTERN=""

usage() {
  cat <<'EOF'
Usage: gfc-logs.sh <service> [options]

Services (control plane):
  api          gfc-api.log
  web          gfc-web.log
  node         co-located gfc-node agent (control host)

Services (forward node):
  agent        gfc-node-agent.log
  sing-box     sing-box.log
  openvpn      openvpn-gfc-backbone.log
  all-fn       all forward-node file logs

Options:
  -n N         show last N lines (default 80)
  -f           follow (tail -f)
  -g PAT       grep pattern (case insensitive)

Examples:
  sudo gfc-logs.sh agent -n 200
  sudo gfc-logs.sh api -f
  sudo gfc-logs.sh sing-box -g error
  sudo gfc-logs.sh openvpn -n 50
  journalctl -u gfc-node-agent -n 100 --no-pager   # if file log missing (legacy)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) LINES="$2"; shift 2 ;;
    -f) FOLLOW=1; shift ;;
    -g) GREP_PATTERN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

SVC="${1:-}"
[[ -n "$SVC" ]] || { usage; exit 1; }

resolve_file() {
  case "$1" in
    api) echo "$CP_LOG_DIR/gfc-api.log" ;;
    web) echo "$CP_LOG_DIR/gfc-web.log" ;;
    node) echo "$CP_LOG_DIR/gfc-node.log" ;;
    agent) echo "$FN_LOG_DIR/gfc-node-agent.log" ;;
    sing-box) echo "$FN_LOG_DIR/sing-box.log" ;;
    openvpn) echo "$FN_LOG_DIR/openvpn-gfc-backbone.log" ;;
    *) return 1 ;;
  esac
}

show_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "WARN: $f not found" >&2
    return 1
  fi
  if [[ -n "$GREP_PATTERN" ]]; then
    if [[ "$FOLLOW" -eq 1 ]]; then
      tail -f "$f" | grep -i --line-buffered "$GREP_PATTERN" || true
    else
      grep -i "$GREP_PATTERN" "$f" | tail -n "$LINES" || true
    fi
  elif [[ "$FOLLOW" -eq 1 ]]; then
    tail -f "$f"
  else
    tail -n "$LINES" "$f"
  fi
}

if [[ "$SVC" == "all-fn" ]]; then
  for name in agent sing-box openvpn; do
    f="$(resolve_file "$name" || true)"
    [[ -f "$f" ]] || continue
    echo "======== $name ($f) ========"
    show_file "$f" || true
    echo ""
  done
  exit 0
fi

FILE="$(resolve_file "$SVC")" || { echo "Unknown service: $SVC"; usage; exit 1; }
show_file "$FILE"
