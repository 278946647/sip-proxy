#!/bin/sh
set -eu

ACTION="${1:-start}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
MARK="${GFC_POLICY_MARK:-0x2023}"
TABLE="${GFC_POLICY_TABLE:-2022}"
NFT_PRIORITY="${GFC_NFT_PRIORITY:-200}"
MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
SINGBOX_UID="${GFC_SINGBOX_UID:-65354}"
GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
DNS_PORT="${GFC_DNSMASQ_PORT:-53}"
LAN_IFACE="${GFC_LAN_IFACE:-$(uci -q get network.lan.device 2>/dev/null || true)}"
LAN_ADDR="${GFC_LAN_ADDRESS:-$(uci -q get network.lan.ipaddr 2>/dev/null || true)}"
LAN_MASK="$(uci -q get network.lan.netmask 2>/dev/null || echo 255.255.255.0)"
CN_AUDIT="${GFC_ETC}/nftables-cn-ip.set"
CN_LOAD="${GFC_ETC}/nftables-cn-ip-load.nft"
BYPASS_AUDIT="${GFC_ETC}/nftables-bypass-ip.set"
BYPASS_LOAD="${GFC_ETC}/nftables-bypass-ip-load.nft"
BUNDLE="${GFC_LIB:-/var/lib/gfc-client}/state/config_bundle.json"

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
	# LAN clients may point DNS at 8.8.8.8 or other resolvers. Redirect them
	# back to dnsmasq:53; dnsmasq then forwards to mosdns:1053 via UCI.
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

  set bypass_ip {
    type ipv4_addr
    flags interval
  }

  chain classify {
    meta mark $MARK return
    ct mark != 0x00000000 meta mark set ct mark return
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    ip daddr $LAN_CIDR return
    tcp dport { 53, 67, 68 } return
    udp dport { 53, 67, 68 } return
    ip daddr @bypass_ip return
    ip daddr @cn_ip return
    meta mark set $MARK
    ct mark set meta mark
  }

  chain prerouting {
    type filter hook prerouting priority $NFT_PRIORITY; policy accept;
    iifname "$LAN_IFACE" ip daddr != $LAN_CIDR jump classify
  }

  chain output {
    type route hook output priority $NFT_PRIORITY; policy accept;
    oif "lo" return
    oifname "$TUN_IFACE" return
    iifname "$TUN_IFACE" return
    meta skuid $SINGBOX_UID return
    meta skuid $MOSDNS_UID ip daddr { 1.0.0.1, 1.1.1.1, 8.8.4.4, 8.8.8.8 } meta mark set $MARK
    meta skuid $MOSDNS_UID tcp dport 443 meta mark set $MARK
    jump classify
  }
}
EOF
}

is_ipv4() {
	echo "$1" | awk -F. 'NF == 4 {
		for (i = 1; i <= 4; i++) {
			if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
		}
		exit 0
	} { exit 1 }'
}

append_bypass_ip() {
	local ip="$1"
	ip="${ip%%/*}"
	[ -n "$ip" ] || return 0
	is_ipv4 "$ip" || return 0
	grep -qx "$ip" "$BYPASS_AUDIT" 2>/dev/null || echo "$ip" >> "$BYPASS_AUDIT"
}

resolve_policy_bypass_ips() {
	mkdir -p "$GFC_ETC"
	: > "$BYPASS_AUDIT"

	for token in $(echo "${GFC_POLICY_BYPASS_IPS:-}" | tr ',' ' '); do
		append_bypass_ip "$token"
	done
	for key in ${GFC_NODE_BYPASS:-} ${GFC_CP_BYPASS:-} ${SERVER_URL:-} ${SERVER_URL_FALLBACK:-}; do
		for ip in $(echo "$key" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true); do
			append_bypass_ip "$ip"
		done
	done

	if [ -f "$BUNDLE" ]; then
		awk '
			/"node"[[:space:]]*:/ { in_node=1 }
			in_node && /"address"[[:space:]]*:/ {
				if (match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) print substr($0, RSTART, RLENGTH)
				in_node=0
			}
			/"controlPlaneServers"[[:space:]]*:/ { in_cp=1 }
			in_cp {
				while (match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
					print substr($0, RSTART, RLENGTH)
					$0 = substr($0, RSTART + RLENGTH)
				}
				if ($0 ~ /\]/) in_cp=0
			}
		' "$BUNDLE" | while read -r ip; do
			append_bypass_ip "$ip"
		done
	fi
}

load_bypass_set() {
	resolve_policy_bypass_ips
	if [ ! -s "$BYPASS_AUDIT" ]; then
		echo "# empty" > "$BYPASS_AUDIT"
		echo "# no bypass ips" > "$BYPASS_LOAD"
		echo "bypass ip set: 0 addresses ($BYPASS_AUDIT)"
		return 0
	fi
	awk 'BEGIN{started=0; n=0}
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
			if (!started) { printf "add element inet gfc_client_mangle bypass_ip { "; started=1; }
			if (n > 0) printf ", ";
			printf "%s/32", $1;
			n++;
		}
		END{ if (started) print " }"; }' "$BYPASS_AUDIT" > "$BYPASS_LOAD"
	nft -f "$BYPASS_LOAD" 2>/dev/null || true
	echo "bypass ip set: $(wc -l < "$BYPASS_AUDIT" 2>/dev/null || echo 0) addresses ($BYPASS_AUDIT)"
}

load_cn_set() {
	[ -f "$CN_LIST" ] || {
		echo "WARN: CN IP list missing: $CN_LIST" >&2
		return 0
	}
	mkdir -p "$GFC_ETC"
	awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/ { print $1 }' "$CN_LIST" > "$CN_AUDIT"
	awk 'BEGIN{n=0; started=0}
		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/ {
			if (!started) { printf "add element inet gfc_client_mangle cn_ip { "; started=1; }
			if (n > 0) printf ", ";
			printf "%s", $1;
			n++;
			if (n == 200) { print " }"; n=0; started=0; }
		}
		END{ if (started) print " }"; }' "$CN_LIST" > "$CN_LOAD"
	nft -f "$CN_LOAD" 2>/dev/null || true
	echo "cn ip set: $(wc -l < "$CN_AUDIT" 2>/dev/null || echo 0) prefixes ($CN_AUDIT)"
}

wait_tun() {
	local i
	for i in $(seq 1 30); do
		ip link show "$TUN_IFACE" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

start_rules() {
	stop_rules
	apply_dns_hijack
	apply_policy_table
	load_cn_set
	load_bypass_set
	wait_tun || {
		echo "WARN: $TUN_IFACE not up; DNS hijack and CN policy set applied, policy route deferred" >&2
		exit 0
	}
	ip -4 rule add pref 100 fwmark "$MARK" lookup "$TABLE" 2>/dev/null || \
		ip -4 rule add fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route replace default dev "$TUN_IFACE" table "$TABLE"
	echo "gfc routing: lan=$LAN_IFACE cidr=$LAN_CIDR mark=$MARK table=$TABLE priority=$NFT_PRIORITY cn=$CN_LIST bypass=$BYPASS_AUDIT"
}

case "$ACTION" in
	start) start_rules ;;
	stop) stop_rules ;;
	restart) stop_rules; start_rules ;;
	status)
		echo "lan=$LAN_IFACE cidr=$LAN_CIDR tun=$TUN_IFACE mark=$MARK table=$TABLE"
		echo "dns_hijack=$(nft list table inet gfc_dns_hijack >/dev/null 2>&1 && echo yes || echo no)"
		echo "policy=$(nft list table inet gfc_client_mangle >/dev/null 2>&1 && echo yes || echo no)"
		echo "cn_list=$CN_LIST"
		echo "cn_audit=$CN_AUDIT"
		echo "bypass_audit=$BYPASS_AUDIT"
		[ -f "$CN_AUDIT" ] && wc -l "$CN_AUDIT" || true
		[ -f "$BYPASS_AUDIT" ] && cat "$BYPASS_AUDIT" || true
		ip -4 rule list | grep "$TABLE" || true
		ip -4 route show table "$TABLE" 2>/dev/null || true
		;;
	*) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
