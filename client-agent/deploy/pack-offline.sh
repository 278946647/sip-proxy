#!/usr/bin/env bash
# Build standalone offline tarballs (client-agent only — no gfc-platform).
set -euo pipefail
_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
OUT="${OUT:-$CLIENT_ROOT/dist}"
VERSION="${VERSION:-0.1.0}"
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.4}"
MOSDNS_VERSION="${MOSDNS_VERSION:-5.3.3}"

if [[ ! -f "$CLIENT_ROOT/client_agent/__init__.py" ]]; then
  echo "ERROR: $CLIENT_ROOT/client_agent missing"
  exit 1
fi

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pack_arch() {
  local sb_arch=$1 mos_arch=$2 label=$3
  local root="$WORK/gfc-client-offline-${label}-${VERSION}"
  mkdir -p "$root/bin" "$root/deploy"

  echo "==> Pack $label (client-agent standalone)"
  rsync -a "$CLIENT_ROOT/" "$root/" \
    --exclude dist --exclude .venv --exclude state --exclude deploy/pack-offline.sh \
    --exclude deploy/build-image.sh
  rsync -a "$_DIR/" "$root/deploy/" \
    --exclude pack-offline.sh --exclude build-image.sh
  cp "$_DIR/install.sh" "$root/install.sh"
  cp "$_DIR/install-ubuntu.sh" "$root/install-ubuntu.sh"
  cp "$_DIR/flash-line-code.sh" "$root/flash-line-code.sh"
  chmod +x "$root"/*.sh "$root/deploy"/*.sh 2>/dev/null || true

  local tmp url
  tmp=$(mktemp -d)
  url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${sb_arch}.tar.gz"
  echo "    sing-box $url"
  curl -fsSL "$url" -o "$tmp/sb.tgz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -name sing-box -type f | head -1)" "$root/bin/sing-box"

  url="https://github.com/IrineSistiana/mosdns/releases/download/v${MOSDNS_VERSION}/mosdns-linux-${mos_arch}.zip"
  echo "    Download mosdns: $url"
  curl -fsSL "$url" -o "$tmp/mosdns.zip"
  unzip -q "$tmp/mosdns.zip" -d "$tmp"
  install -m 755 "$(find "$tmp" -name mosdns -type f | head -1)" "$root/bin/mosdns"
  rm -rf "$tmp"

  cat >"$root/README.txt" <<EOF
GFC Client Offline Package ${VERSION} (${label}) — standalone, no control plane code
1. Copy tar to Ubuntu 22.04 device
2. tar xzf gfc-client-offline-${label}-${VERSION}.tar.gz && cd gfc-client-offline-${label}-${VERSION}
3. sudo bash flash-line-code.sh /path/to/linecode.b32
4. sudo bash install.sh --config deploy/install.env.example --yes
EOF

  tar -czf "$OUT/gfc-client-offline-${label}-${VERSION}.tar.gz" -C "$WORK" "gfc-client-offline-${label}-${VERSION}"
  echo "    -> $OUT/gfc-client-offline-${label}-${VERSION}.tar.gz"
}

pack_arch amd64 amd64 x86_64
pack_arch arm64 arm64 aarch64

echo "==> Offline packages in $OUT"
ls -lh "$OUT"/*.tar.gz
