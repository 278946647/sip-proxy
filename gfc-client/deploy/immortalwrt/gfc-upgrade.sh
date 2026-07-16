#!/bin/sh
# gfc-upgrade — local runtime package helper (CLI)
# Usage:
#   gfc-upgrade status
#   gfc-upgrade apply --file /tmp/gfc-runtime-xxx.tar.gz
set -eu

API="${GFC_API:-http://127.0.0.1:8080/api/v1}"

cmd_status() {
	wget -qO- "$API/upgrade/status" || curl -fsS "$API/upgrade/status"
	echo
}

cmd_apply_file() {
	file="${1:-}"
	[ -n "$file" ] || { echo "usage: gfc-upgrade apply --file PATH" >&2; exit 1; }
	[ -f "$file" ] || { echo "file not found: $file" >&2; exit 1; }
	body=$(printf '{"path":"%s"}' "$file")
	wget -qO- --header='Content-Type: application/json' --post-data="$body" \
		"$API/upgrade/apply-local" || \
	curl -fsS -H 'Content-Type: application/json' -d "$body" "$API/upgrade/apply-local"
	echo
}

case "${1:-}" in
status)
	cmd_status
	;;
apply)
	shift || true
	case "${1:-}" in
	--file)
		cmd_apply_file "${2:-}"
		;;
	*)
		echo "usage: gfc-upgrade apply --file PATH" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "usage: gfc-upgrade status | apply --file PATH" >&2
	exit 1
	;;
esac
