#!/usr/bin/env bash
# Build standalone offline tarballs (gfc-client only — no gfc-platform).
set -euo pipefail
_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
OUT="${OUT:-$CLIENT_ROOT/dist}"
VERSION="${VERSION:-1.0.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"

if [[ ! -f "$CLIENT_ROOT/go.mod" ]]; then
  echo "ERROR: $CLIENT_ROOT/go.mod missing"
  exit 1
fi

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pack_arch() {
  local sb_arch=$1 label=$2
  local root="$WORK/gfc-client-offline-${label}-${VERSION}"
  mkdir -p "$root/bin" "$root/deploy" "$root/share/rules"

  echo "==> Pack $label (gfc-client standalone)"
  rsync -a "$CLIENT_ROOT/" "$root/" \
    --exclude dist --exclude web/node_modules --exclude web/dist --exclude web-static \
    --exclude .git --exclude bin

  cp -a "$CLIENT_ROOT/share/rules/." "$root/share/rules/" 2>/dev/null || true

  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}.tar.gz"
  echo "    sing-box $url"
  curl -fsSL "$url" -o "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" "$root/bin/sing-box"

  # shellcheck source=install-mosdns-bin.sh
  source "$_DIR/install-mosdns-bin.sh"
  MOS_ARCH=$sb_arch install_mosdns_bin "$root/bin/mosdns"
  rm -rf "$tmp"

  chmod +x "$root/deploy"/*.sh 2>/dev/null || true

  cat >"$root/README.txt" <<EOF
GFC Client Offline Package ${VERSION} (${label})
1. Copy tar to Ubuntu 22.04 device
2. tar xzf gfc-client-offline-${label}-${VERSION}.tar.gz && cd gfc-client-offline-${label}-${VERSION}
3. sudo bash deploy/flash-line-code.sh --file /path/to/linecode.b32   # optional before install
4. sudo bash deploy/install-ubuntu.sh
EOF

  tar -czf "$OUT/gfc-client-offline-${label}-${VERSION}.tar.gz" -C "$WORK" "gfc-client-offline-${label}-${VERSION}"
  echo "    -> $OUT/gfc-client-offline-${label}-${VERSION}.tar.gz"
}

pack_arch amd64 x86_64
pack_arch arm64 aarch64

echo "==> Offline packages in $OUT"
ls -lh "$OUT"/*.tar.gz
