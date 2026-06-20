#!/bin/sh
set -eu

ACTION="${1:-start}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
MARK="${GFC_POLICY_MARK:-0x2023}"
TABLE="${GFC_POLICY_TABLE:-2022}"
GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
DNS_PORT="${GFC_DNSMASQ_PORT:-53}"
LAN_IFACE="${GFC_LAN_IFACE:-$(uci -q get network.lan.device 2>/dev/null || true)}"
LAN_ADDR="${GFC_LAN_ADDRESS:-$(uci -q get network.lan.ipaddr 2>/dev/null || true)}"
LAN_MASK="$(uci -q get network.lan.netmask 2>/dev/null || echo 255.255.255.0)"

[ -n "$LAN_IFACE" ] || LAN_IFACE="br-lan"
[ -n "$LAN_ADDR" ] || LAN_ADDR="192.168.1.1"

mask_prefix() {
	case "$1" in
		255.255.255.255) echo 32 ;;
		255.255.255.252) echo 30 ;;
		255.255.255.248) echo 29 ;;
		255.255.255.240) echo 28 ;;
		255.255.255.224) echo 27 ;;
		255.255.255.192) echo 26 ;;
		255.255.255.128) echo 25 ;;
		255.255.255.0) echo 24 ;;
		255.255.254.0) echo 23 ;;
		255.255.252.0) echo 22 ;;
		255.255.248.0) echo 21 ;;
		255.255.240.0) echo 20 ;;
		255.255.224.0) echo 19 ;;
		255.255.192.0) echo 18 ;;
		255.255.128.0) echo 17 ;;
		255.255.0.0) echo 16 ;;
		*) echo 24 ;;
	esac
}

network_cidr() {
	local ip="$1" prefix="$2"
	awk -F. -v p="$prefix" '{ if (p == 24) printf "%s.%s.%s.0/24\n",$1,$2,$3; else print $0"/"p }' <<EOF
$ip
EOF
}

LAN_CIDR="${GFC_LAN_CIDR:-$(network_cidr "$LAN_ADDR" "$(mask_prefix "$LAN_MASK")")}"
CN_LIST="${GFC_CN_IP_LIST:-$GFC_ETC/mosdns/easymosdns/rules/china_ip_list.txt}"
[ -f "$CN_LIST" ] || CN_LIST="$GFC_ROOT/share/easymosdns/rules/china_ip_list.txt"

stop_rules() {
	ip -4 rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route flush table "$TABLE" 2>/dev/null || true
	nft delete table inet gfc_client_mangle 2>/dev/null || true
	nft delete table inet gfc_dns_hijack 2>/dev/null || true
}

apply_dns_hijack() {
	nft -f - <<EOF
table inet gfc_dns_hijack {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$LAN_IFACE" udp dport 53 redirect to :$DNS_PORT
    iifname "$LAN_IFACE" tcp dport 53 redirect to :$DNS_PORT
  }
}
EOF
}

apply_policy_table() {
	nft -f - <<EOF
table inet gfc_client_mangle {
  set cn_ip {
    type ipv4_addr
    flags interval
  }

  chain classify {
    meta mark $MARK return
    ct mark != 0x00000000 meta mark set ct mark return
    ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } return
    ip daddr $LAN_CIDR return
    tcp dport { 53, 67, 68 } return
    udp dport { 53, 67, 68 } return
    ip daddr @cn_ip return
    meta mark set $MARK
    ct mark set meta mark
  }

  chain prerouting {
    type filter hook prerouting priority -150; policy accept;
    iifname "$LAN_IFACE" jump classify
  }
}
EOF
}

load_cn_set() {
	[ -f "$CN_LIST" ] || {
		echo "WARN: CN IP list missing: $CN_LIST" >&2
		return 0
	}
	awk 'BEGIN{n=0; started=0}
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/ {
			if (!started) { printf "add element inet gfc_client_mangle cn_ip { "; started=1; }
			if (n > 0) printf ", ";
			printf "%s", $1;
			n++;
			if (n == 200) { print " }"; n=0; started=0; }
		}
		END{ if (started) print " }"; }' "$CN_LIST" | nft -f - 2>/dev/null || true
}

start_rules() {
	stop_rules
	apply_dns_hijack
	ip link show "$TUN_IFACE" >/dev/null 2>&1 || {
		echo "WARN: $TUN_IFACE not up; DNS hijack applied, policy route deferred" >&2
		exit 0
	}
	apply_policy_table
	load_cn_set
	ip -4 rule add pref 100 fwmark "$MARK" lookup "$TABLE" 2>/dev/null || \
		ip -4 rule add fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route replace default dev "$TUN_IFACE" table "$TABLE"
	echo "gfc routing: lan=$LAN_IFACE cidr=$LAN_CIDR mark=$MARK table=$TABLE cn=$CN_LIST"
}

case "$ACTION" in
	start) start_rules ;;
	stop) stop_rules ;;
	restart) stop_rules; start_rules ;;
	*) echo "usage: $0 {start|stop|restart}" >&2; exit 2 ;;
esac
