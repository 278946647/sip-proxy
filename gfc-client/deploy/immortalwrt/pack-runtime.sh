#!/usr/bin/env bash
# Build a field-test runtime bundle for ImmortalWrt/OpenWrt devices.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OUT:-$ROOT/dist}"
VERSION="${VERSION:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)}"
GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-amd64}"
GOARM="${GOARM:-}"
CGO_ENABLED="${CGO_ENABLED:-0}"
LABEL="${LABEL:-$GOARCH${GOARM:+v$GOARM}}"

if [[ ! -f "$ROOT/go.mod" ]]; then
  echo "ERROR: go.mod not found at $ROOT" >&2
  exit 1
fi

mkdir -p "$OUT" "$ROOT/bin"

echo "==> Build GFC binaries for $GOOS/$GOARCH${GOARM:+ GOARM=$GOARM}"
build_go() {
  local pkg=$1 out=$2
  if [[ -n "$GOARM" ]]; then
    GOOS="$GOOS" GOARCH="$GOARCH" GOARM="$GOARM" CGO_ENABLED="$CGO_ENABLED" \
      go build -trimpath -ldflags "-s -w" -o "$out" "$pkg"
  else
    GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED="$CGO_ENABLED" \
      go build -trimpath -ldflags "-s -w" -o "$out" "$pkg"
  fi
}

build_go ./cmd/gfc-api "$ROOT/bin/gfc-api"
build_go ./cmd/gfc-agent "$ROOT/bin/gfc-agent"
build_go ./cmd/gfc-bootstrap "$ROOT/bin/gfc-bootstrap"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG="gfc-immortalwrt-runtime-${LABEL}-${VERSION}"
STAGE="$WORK/$PKG"
mkdir -p "$STAGE/bin" "$STAGE/usr/lib/gfc-client"

install -m 755 "$ROOT/bin/gfc-api" "$STAGE/bin/gfc-api"
install -m 755 "$ROOT/bin/gfc-agent" "$STAGE/bin/gfc-agent"
install -m 755 "$ROOT/bin/gfc-bootstrap" "$STAGE/bin/gfc-bootstrap"
cp -a "$ROOT/deploy" "$STAGE/usr/lib/gfc-client/"
cp -a "$ROOT/share" "$STAGE/usr/lib/gfc-client/"
chmod +x "$STAGE/usr/lib/gfc-client/deploy/immortalwrt/"*.sh 2>/dev/null || true

cat >"$STAGE/install.sh" <<'EOF'
#!/bin/sh
set -eu

cp bin/gfc-api /tmp/gfc-api
cp bin/gfc-agent /tmp/gfc-agent
cp bin/gfc-bootstrap /tmp/gfc-bootstrap
mkdir -p /usr/lib/gfc-client
cp -a usr/lib/gfc-client/deploy /usr/lib/gfc-client/
cp -a usr/lib/gfc-client/share /usr/lib/gfc-client/
chmod +x /usr/lib/gfc-client/deploy/immortalwrt/*.sh

if [ -x /usr/lib/gfc-client/deploy/immortalwrt/upgrade-runtime.sh ]; then
	/usr/lib/gfc-client/deploy/immortalwrt/upgrade-runtime.sh
else
	mv /tmp/gfc-api /usr/bin/gfc-api
	mv /tmp/gfc-agent /usr/bin/gfc-agent
	mv /tmp/gfc-bootstrap /usr/bin/gfc-bootstrap
	chmod +x /usr/bin/gfc-api /usr/bin/gfc-agent /usr/bin/gfc-bootstrap
	/usr/lib/gfc-client/deploy/immortalwrt/install-runtime.sh
	/usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh
fi
EOF
chmod +x "$STAGE/install.sh"

cat >"$STAGE/README.txt" <<EOF
GFC ImmortalWrt runtime bundle
Version: $VERSION
Target: $GOOS/$GOARCH${GOARM:+ GOARM=$GOARM}

Install on device:
  tar xzf ${PKG}.tar.gz
  cd ${PKG}
  ./install.sh

This bundle does not include sing-box or mosdns binaries. Install or upload them
separately to /usr/bin/sing-box and /usr/bin/mosdns before active dataplane tests.
EOF

tar -czf "$OUT/${PKG}.tar.gz" -C "$WORK" "$PKG"
echo "==> $OUT/${PKG}.tar.gz"
