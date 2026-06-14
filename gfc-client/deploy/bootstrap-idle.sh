#!/usr/bin/env bash
# Render idle mosdns + sing-box configs and restart data plane services.
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
if [[ -d "$SRC_ROOT/share/easymosdns" ]]; then
  mkdir -p "$GFC_ROOT/share"
  rsync -a "$SRC_ROOT/share/easymosdns/" "$GFC_ROOT/share/easymosdns/"
fi

systemctl stop gfc-mosdns gfc-client-sing-box 2>/dev/null || true
bash "$SCRIPT_DIR/singbox-nft-cleanup.sh" 2>/dev/null || true

echo "==> Bootstrap idle dataplane"
"$BIN"
systemctl restart gfc-mosdns gfc-client-sing-box
echo "    mosdns: $(systemctl is-active gfc-mosdns 2>/dev/null || echo unknown)"
echo "    sing-box: $(systemctl is-active gfc-client-sing-box 2>/dev/null || echo unknown)"
