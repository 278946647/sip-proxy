#!/usr/bin/env bash
# GFC client install — repo (deploy/install.sh) or offline tar (./install.sh at tar root)
set -euo pipefail
_self="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$_self")" && pwd)"

if [[ -f "$_DIR/client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$_DIR"
  DEPLOY_DIR="$_DIR/deploy"
elif [[ -f "$_DIR/../client_agent/__init__.py" ]]; then
  CLIENT_ROOT="$(cd "$_DIR/.." && pwd)"
  DEPLOY_DIR="$_DIR"
else
  echo "ERROR: client_agent package not found"
  exit 1
fi

CONFIG_FILE=""
NON_INTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE=${2:-}; shift 2 ;;
    --yes) NON_INTERACTIVE=1; shift ;;
    -h|--help)
      echo "Usage: sudo bash $0 [--config deploy/install.env.example] [--yes]"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

if [[ $NON_INTERACTIVE -eq 0 && -t 0 ]]; then
  echo "Client root: $CLIENT_ROOT"
  read -r -p "Continue install? [Y/n]: " ok
  [[ -z "$ok" || "$ok" =~ ^[Yy]$ ]] || exit 0
fi

export CLIENT_ROOT
bash "$DEPLOY_DIR/install-ubuntu.sh"
systemctl restart gfc-client-agent 2>/dev/null || true
echo "Done."
