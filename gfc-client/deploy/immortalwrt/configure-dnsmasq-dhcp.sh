#!/bin/sh
# dnsmasq: DHCP only (port=0). Advertise LAN gateway as DNS (DHCP option 6).
# unbound (gfc-unbound) owns DNS :53.
set -eu

if ! command -v uci >/dev/null 2>&1; then
	exit 0
fi

LAN_ADDR="${GFC_LAN_ADDRESS:-}"
if [ -z "$LAN_ADDR" ]; then
	LAN_ADDR="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
fi
[ -n "$LAN_ADDR" ] || LAN_ADDR="192.168.1.1"

uci set dhcp.@dnsmasq[0].port='0'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci set dhcp.@dnsmasq[0].cachesize='0'

if ! uci -q get dhcp.lan >/dev/null 2>&1; then
	uci set dhcp.lan=dhcp
	uci set dhcp.lan.interface='lan'
fi
uci -q delete dhcp.lan.ignore

# DHCP option 6 = DNS servers → LAN gateway (unbound on :53).
# Remove prior option-6 entries only; keep other custom dhcp_option values.
while true; do
	found=0
	for opt in $(uci -q get dhcp.lan.dhcp_option 2>/dev/null); do
		case "$opt" in
		6,*|6\ *)
			uci del_list dhcp.lan.dhcp_option="$opt"
			found=1
			break
			;;
		esac
	done
	[ "$found" = "0" ] && break
done
uci add_list dhcp.lan.dhcp_option="6,$LAN_ADDR"

uci commit dhcp
echo "dnsmasq DHCP: port=0, dns=$LAN_ADDR"
