#!/usr/bin/env bash
# Write Base32 line code to device activation file
set -euo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash flash-line-code.sh LINE_CODE_FILE_OR_STRING"
  echo "       sudo bash flash-line-code.sh --file /media/usb/line.b32"
  exit 1
fi

TARGET="${ACTIVATION_FILE:-/etc/gfc-client/activation.b32}"
mkdir -p "$(dirname "$TARGET")"

if [[ "$1" == "--file" ]]; then
  SRC="${2:?missing file path}"
  install -m 600 "$SRC" "$TARGET"
elif [[ -f "$1" ]]; then
  install -m 600 "$1" "$TARGET"
else
  printf '%s' "$1" >"$TARGET"
  chmod 600 "$TARGET"
fi

echo "Line code written to $TARGET"
if systemctl is-enabled gfc-client-agent >/dev/null 2>&1; then
  systemctl restart gfc-client-agent
  echo "Restarted gfc-client-agent"
fi
