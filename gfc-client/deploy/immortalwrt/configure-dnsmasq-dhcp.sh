#!/bin/sh
# dnsmasq: DHCP only (port=0). Advertise LAN gateway as DNS (DHCP option 6).
# unbound (gfc-unbound) owns DNS :53.
#
# Note: with port=0 dnsmasq does NOT auto-advertise itself as DNS; option 6 is required.

if ! command -v uci >/dev/null 2>&1; then
	exit 0
fi

LAN_ADDR="${GFC_LAN_ADDRESS:-}"
if [ -z "$LAN_ADDR" ]; then
	LAN_ADDR="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
fi
# UCI may return multiple addresses; use the first IPv4-looking token.
LAN_ADDR="$(echo "$LAN_ADDR" | tr ' \t' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)"
if [ -z "$LAN_ADDR" ]; then
	LAN_ADDR="192.168.1.1"
fi

uci set dhcp.@dnsmasq[0].port='0'
uci set dhcp.@dnsmasq[0].noresolv='1'
# Force DHCP even if another server is detected on the segment (lab/cascade).
# Without this, dnsmasq refuses DHCP and LAN clients get no address.
uci set dhcp.@dnsmasq[0].force='1'
uci -q delete dhcp.@dnsmasq[0].server
uci set dhcp.@dnsmasq[0].cachesize='0'

if ! uci -q get dhcp.lan >/dev/null 2>&1; then
	uci set dhcp.lan=dhcp
	uci set dhcp.lan.interface='lan'
fi
uci -q delete dhcp.lan.ignore

# Rebuild dhcp_option: keep non-6 entries, force option 6 = LAN gateway.
# (Do not use set -e around `uci get` — missing list exits 1 and would abort before add_list.)
keep=""
for opt in $(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true); do
	case "$opt" in
	6,*|6\ *) ;;
	*) keep="$keep $opt" ;;
	esac
done
uci -q delete dhcp.lan.dhcp_option
for opt in $keep; do
	uci add_list dhcp.lan.dhcp_option="$opt"
done
uci add_list dhcp.lan.dhcp_option="6,$LAN_ADDR"

# odhcpd RA DNS (IPv6 clients), ignore if unsupported.
uci -q delete dhcp.lan.dns 2>/dev/null || true
uci add_list dhcp.lan.dns="$LAN_ADDR" 2>/dev/null || true

uci commit dhcp

got="$(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true)"
echo "dnsmasq DHCP: port=0, force=1, dns=$LAN_ADDR, dhcp_option=$got"
case " $got " in
*" 6,$LAN_ADDR "*|*"6,$LAN_ADDR"*) ;;
*)
	echo "ERROR: dhcp.lan.dhcp_option missing 6,$LAN_ADDR" >&2
	exit 1
	;;
esac

# Apply immediately when running on a live device (not image build).
if [ -z "${IPKG_INSTROOT:-}" ] && [ -x /etc/init.d/dnsmasq ]; then
	/etc/init.d/dnsmasq restart 2>/dev/null || true
fi
