#!/usr/bin/env bash
# Re-apply mosdns + sing-box from local config bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/reapply-active.sh"
