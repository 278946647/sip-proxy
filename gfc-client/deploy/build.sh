#!/usr/bin/env bash
# Build Go binaries and Vue3 web UI on Ubuntu 22.04+
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Go build"
if ! command -v go >/dev/null 2>&1; then
  echo "Go not found. Install: apt install golang-go  or  snap install go --classic"
  exit 1
fi
go mod tidy
mkdir -p "$ROOT/bin"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/bin/gfc-api" ./cmd/gfc-api
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/bin/gfc-agent" ./cmd/gfc-agent
echo "    bin/gfc-api bin/gfc-agent"

echo "==> Vue3 build"
if command -v npm >/dev/null 2>&1; then
  (cd "$ROOT/web" && npm ci && npm run build)
  rm -rf "$ROOT/web-static"
  cp -a "$ROOT/web/dist" "$ROOT/web-static"
  echo "    web-static/"
else
  echo "WARN: npm not found, skip web build (install nodejs on target)"
fi

echo "==> Done"
