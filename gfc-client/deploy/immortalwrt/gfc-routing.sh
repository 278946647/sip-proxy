#!/bin/sh
set -eu

ACTION="${1:-start}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
WAN_IFACE="${GFC_WAN_IFACE:-eth0}"
MARK="${GFC_POLICY_MARK:-0x2023}"
TABLE="${GFC_POLICY_TABLE:-2022}"
ROUTING_SCHEME="${GFC_ROUTING_SCHEME:-kernel-split}"
REDIRECT_PORT="${GFC_REDIRECT_PORT:-11800}"
SSH_PORT="${GFC_SSH_PORT:-212}"
EXT_CONST_IPS="${GFC_EXT_CONST_IPS:-8.8.4.4,8.8.8.8,1.1.1.1,1.0.0.1}"
NFT_PRIORITY="${GFC_NFT_PRIORITY:-200}"
OUTPUT_POLICY="${GFC_ENABLE_OUTPUT_POLICY:-1}"
MOSDNS_USER="${GFC_MOSDNS_USER:-mosdns}"
MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
SINGBOX_USER="${GFC_SINGBOX_USER:-singbox}"
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

if id -u "$MOSDNS_USER" >/dev/null 2>&1; then
	MOSDNS_UID="$(id -u "$MOSDNS_USER" 2>/dev/null || echo "$MOSDNS_UID")"
fi
if id -u "$SINGBOX_USER" >/dev/null 2>&1; then
	SINGBOX_UID="$(id -u "$SINGBOX_USER" 2>/dev/null || echo "$SINGBOX_UID")"
fi

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

is_ipv4() {
	echo "$1" | awk -F. 'NF == 4 {
		for (i = 1; i <= 4; i++) {
			if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
		}
		exit 0
	} { exit 1 }'
}

LAN_CIDR="${GFC_LAN_CIDR:-$(network_cidr "$LAN_ADDR" "$(mask_prefix "$LAN_MASK")")}"
CN_LIST="${GFC_CN_IP_LIST:-$GFC_ETC/mosdns/easymosdns/rules/china_ip_list.txt}"
[ -f "$CN_LIST" ] || CN_LIST="$GFC_ROOT/share/easymosdns/rules/china_ip_list.txt"

stop_rules() {
	ip -4 rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route flush table "$TABLE" 2>/dev/null || true
	nft delete table inet gfc 2>/dev/null || true
	nft delete table inet gfc_client_mangle 2>/dev/null || true
	nft delete table inet gfc_dns_hijack 2>/dev/null || true
	nft delete table inet nat 2>/dev/null || true
}

apply_wan_nat() {
	nft -f - <<EOF
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WAN_IFACE" masquerade
  }
}
EOF
}

apply_dns_hijack() {
	# LAN clients may point DNS at 8.8.8.8 or other resolvers. Redirect them
	# to local unbound:53 (dnsmasq is DHCP-only with port=0).
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

fmt_ext_const_elements() {
	local out="" token
	for token in $(echo "$EXT_CONST_IPS" | tr ',' ' '); do
		token="${token%%/*}"
		[ -n "$token" ] || continue
		is_ipv4 "$token" || continue
		[ -n "$out" ] && out="$out, "
		out="${out}${token}"
	done
	[ -n "$out" ] || out="8.8.4.4, 8.8.8.8, 1.1.1.1, 1.0.0.1"
	echo "$out"
}

apply_policy_table_architecture() {
	local ext_const
	ext_const="$(fmt_ext_const_elements)"
	nft -f - <<EOF
table inet gfc {
  set TO_CN {
    type ipv4_addr
    flags interval
  }

  set TO_RFC1918 {
    type ipv4_addr
    flags interval
    elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
  }

  set bypass_ip {
    type ipv4_addr
    flags interval
  }

  set ext {
    type ipv4_addr
    size 262144
    timeout 2h
  }

  set ext_const {
    type ipv4_addr
    elements = { $ext_const }
  }

  chain prerouting_mangle_ct {
    type filter hook prerouting priority mangle; policy accept;
    iifname "$LAN_IFACE" ct mark set $MARK accept
  }

  chain prerouting_mangle_route {
    type filter hook prerouting priority filter; policy accept;
    iifname "$LAN_IFACE" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    iifname "$LAN_IFACE" ip daddr $LAN_CIDR return
    iifname "$LAN_IFACE" udp dport { 53, 67, 68, 123 } return
    iifname "$LAN_IFACE" ip daddr @bypass_ip return
    iifname "$LAN_IFACE" ip daddr @ext_const ct mark $MARK meta mark set ct mark return
    iifname "$LAN_IFACE" ip daddr @TO_CN return
    iifname "$LAN_IFACE" ct mark $MARK meta mark set ct mark
  }

  chain gfc_forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    ct state new ip saddr $LAN_CIDR ct mark set meta mark
    accept
  }

  chain output_mangle_route {
    type route hook output priority filter; policy accept;
    meta mark != 0x00000000 return
    tcp dport $SSH_PORT return
    ip daddr @TO_RFC1918 return
    ip daddr 127.0.0.0/8 return
    ip daddr @TO_CN return
    ip daddr @bypass_ip counter return
    meta mark set $MARK
    ct mark set meta mark
  }
}
EOF
}

apply_policy_table_kernel_split() {
	apply_policy_table_architecture
}

apply_policy_table_byst_redirect() {
	local ext_const
	ext_const="$(fmt_ext_const_elements)"
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

  set ext {
    type ipv4_addr
    flags timeout
    timeout 7200s
    size 262144
  }

  set ext_const {
    type ipv4_addr
    elements = { $ext_const }
  }

  chain mark_proxy {
    meta mark set $MARK
    ct mark set meta mark
    accept
  }

  chain classify_non_tcp {
    meta mark set ct mark
    meta mark $MARK accept
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    ip daddr $LAN_CIDR return
    udp dport { 53, 67, 68, 123 } return
    ip daddr @bypass_ip return
    ip daddr @ext_const jump mark_proxy
    ip daddr @ext jump mark_proxy
    ip daddr != @cn_ip jump mark_proxy
    ct mark set meta mark
    accept
  }

  chain redirect_tcp {
    ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    ip daddr $LAN_CIDR return
    ip daddr @bypass_ip return
    meta l4proto tcp ip daddr @ext redirect to :$REDIRECT_PORT
    meta l4proto tcp ip daddr @ext_const redirect to :$REDIRECT_PORT
    meta l4proto tcp ip daddr != @cn_ip redirect to :$REDIRECT_PORT
  }

  chain prerouting_mangle {
    type filter hook prerouting priority mangle; policy accept;
    iifname "$LAN_IFACE" meta l4proto != tcp jump classify_non_tcp
  }

  chain output_mangle {
    type route hook output priority mangle; policy accept;
    meta mark != 0x00000000 accept
    oif "lo" return
    oifname "$TUN_IFACE" return
    iifname "$TUN_IFACE" return
    meta skuid $SINGBOX_UID return
    meta l4proto tcp tcp sport $SSH_PORT return
    udp dport 123 return
    oifname "$WAN_IFACE" meta l4proto != tcp jump classify_non_tcp
  }

  chain prerouting_nat {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$LAN_IFACE" meta l4proto tcp ip daddr != @cn_ip redirect to :$REDIRECT_PORT
    iifname "$LAN_IFACE" meta l4proto tcp jump redirect_tcp
  }

  chain output_nat {
    type nat hook output priority dstnat; policy accept;
    meta mark != 0x00000000 accept
    oif "lo" return
    oifname "$TUN_IFACE" return
    meta skuid $SINGBOX_UID return
    meta l4proto tcp tcp sport $SSH_PORT return
    iifname "$WAN_IFACE" meta l4proto tcp ip daddr != @cn_ip redirect to :$REDIRECT_PORT
    oifname "$WAN_IFACE" meta l4proto tcp jump redirect_tcp
  }
}
EOF
}

apply_policy_table() {
	case "$ROUTING_SCHEME" in
		byst-redirect) apply_policy_table_byst_redirect ;;
		*) apply_policy_table_kernel_split ;;
	esac
}

apply_output_policy_kernel_split() {
	# output_mangle_route is defined in inet gfc (architecture).
	:
}

apply_output_policy() {
	case "$ROUTING_SCHEME" in
		byst-redirect) return 0 ;;
		*) apply_output_policy_kernel_split ;;
	esac
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
			if (!started) { printf "add element inet gfc bypass_ip { "; started=1; }
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
			if (!started) { printf "add element inet gfc TO_CN { "; started=1; }
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
	apply_wan_nat
	apply_dns_hijack
	apply_policy_table
	apply_output_policy
	load_cn_set
	load_bypass_set
	wait_tun || {
		echo "WARN: $TUN_IFACE not up; DNS hijack and CN policy set applied, policy route deferred" >&2
		exit 0
	}
	ip -4 rule add pref 100 fwmark "$MARK" lookup "$TABLE" 2>/dev/null || \
		ip -4 rule add fwmark "$MARK" table "$TABLE" 2>/dev/null || true
	ip -4 route replace default dev "$TUN_IFACE" table "$TABLE"
	echo "gfc routing: scheme=$ROUTING_SCHEME lan=$LAN_IFACE wan=$WAN_IFACE cidr=$LAN_CIDR mark=$MARK table=$TABLE redirect=$REDIRECT_PORT ssh=$SSH_PORT priority=$NFT_PRIORITY output=$OUTPUT_POLICY mosdns_uid=$MOSDNS_UID singbox_uid=$SINGBOX_UID cn=$CN_LIST bypass=$BYPASS_AUDIT"
}

case "$ACTION" in
	start) start_rules ;;
	stop) stop_rules ;;
	restart) stop_rules; start_rules ;;
	status)
		echo "scheme=$ROUTING_SCHEME lan=$LAN_IFACE wan=$WAN_IFACE cidr=$LAN_CIDR tun=$TUN_IFACE mark=$MARK table=$TABLE redirect=$REDIRECT_PORT ssh=$SSH_PORT"
		echo "dns_hijack=$(nft list table inet gfc_dns_hijack >/dev/null 2>&1 && echo yes || echo no)"
		echo "policy=$(nft list table inet gfc >/dev/null 2>&1 && echo yes || echo no)"
		echo "cn_list=$CN_LIST"
		echo "cn_audit=$CN_AUDIT"
		echo "bypass_audit=$BYPASS_AUDIT"
		echo "output_policy=$OUTPUT_POLICY"
		echo "mosdns_user=$MOSDNS_USER uid=$MOSDNS_UID"
		echo "singbox_user=$SINGBOX_USER uid=$SINGBOX_UID"
		[ -f "$CN_AUDIT" ] && wc -l "$CN_AUDIT" || true
		[ -f "$BYPASS_AUDIT" ] && cat "$BYPASS_AUDIT" || true
		ip -4 rule list | grep "$TABLE" || true
		ip -4 route show table "$TABLE" 2>/dev/null || true
		;;
	*) echo "usage: $0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
