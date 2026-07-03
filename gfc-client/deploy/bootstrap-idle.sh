#!/usr/bin/env bash
# Render idle configs only; service start is handled by start-services.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFC_ROOT="${GFC_ROOT:-/opt/gfc-client}"
GFC_ENV="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[[ -f "$GFC_ENV" ]] && set -a && source "$GFC_ENV" && set +a

BIN="${GFC_BOOTSTRAP_BIN:-/usr/local/bin/gfc-bootstrap}"
if [[ ! -x "$BIN" && -x "$GFC_ROOT/bin/gfc-bootstrap" ]]; then
  BIN="$GFC_ROOT/bin/gfc-bootstrap"
fi
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: gfc-bootstrap not found (run deploy/build.sh first)" >&2
  exit 1
fi

SRC_ROOT="${GFC_SRC_ROOT:-/opt/sip-proxy/gfc-client}"
if [[ -d "$SRC_ROOT/share/unbound" ]]; then
  mkdir -p "$GFC_ROOT/share"
  rsync -a "$SRC_ROOT/share/unbound/" "$GFC_ROOT/share/unbound/"
fi

echo "    stop data plane (for clean render)..."
systemctl stop gfc-sing-box gfc-unbound gfc-mosdns 2>/dev/null || true
bash "$SCRIPT_DIR/singbox-nft-cleanup.sh" 2>/dev/null || true

echo "==> Bootstrap idle dataplane"
echo "    render configs (timeout 120s)..."
if ! timeout 120 "$BIN"; then
  echo "ERROR: gfc-bootstrap failed or timed out" >&2
  exit 1
fi

echo "    start Unbound (router-only idle)..."
bash "$SCRIPT_DIR/fix-unbound-start.sh" || echo "    WARN: fix-unbound-start failed"

echo "==> Bootstrap idle done"
