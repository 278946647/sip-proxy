#!/bin/sh
set -eu

ACTION="${1:-start}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
MARK="${GFC_POLICY_MARK:-0x2023}"
TABLE="${GFC_POLICY_TABLE:-2022}"

stop_rules() {
	ip -4 rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route flush table "$TABLE" 2>/dev/null || true
	nft delete table inet gfc_client_mangle 2>/dev/null || true
}

start_rules() {
	stop_rules
	ip link show "$TUN_IFACE" >/dev/null 2>&1 || exit 0
	ip -4 rule add fwmark "$MARK" table "$TABLE" priority 100 2>/dev/null || true
	ip -4 route replace default dev "$TUN_IFACE" table "$TABLE"
}

case "$ACTION" in
	start) start_rules ;;
	stop) stop_rules ;;
	restart) stop_rules; start_rules ;;
	*) echo "usage: $0 {start|stop|restart}" >&2; exit 2 ;;
esac
