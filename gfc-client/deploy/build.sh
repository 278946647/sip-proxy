#!/usr/bin/env bash
# Build Go binaries and Vue3 web UI on Ubuntu 22.04+
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=install-go.sh
source "$ROOT/deploy/install-go.sh"
ensure_go

echo "==> Go build"
go mod tidy
mkdir -p "$ROOT/bin"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/bin/gfc-api" ./cmd/gfc-api
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/bin/gfc-agent" ./cmd/gfc-agent
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$ROOT/bin/gfc-bootstrap" ./cmd/gfc-bootstrap
echo "    bin/gfc-api bin/gfc-agent bin/gfc-bootstrap"

echo "==> Done (LuCI is the management UI; Vue web build skipped)"
