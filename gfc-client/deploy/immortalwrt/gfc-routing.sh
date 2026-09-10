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
if [ -f "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh" ]; then
	. "$GFC_ROOT/deploy/immortalwrt/lib-gfc-paths.sh"
	gfc_resolve_lib
fi
BUNDLE="${GFC_LIB:-/etc/gfc-client/lib}/state/config_bundle.json"

[ -n "$LAN_IFACE" ] || LAN_IFACE="br-lan"
[ -n "$LAN_ADDR" ] || LAN_ADDR="192.168.68.1"

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

# Hitch CE must be a real unicast host (TRANSPARENT_MODE.md: learn hosts, not APIPA).
is_hitch_ce() {
	is_ipv4 "$1" || return 1
	case "$1" in
		127.*|169.254.*|224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|236.*|237.*|238.*|239.*|255.*)
			return 1 ;;
		172.31.252.*|172.31.253.*)
			return 1 ;;
		172.19.0.0|172.19.0.1|172.19.0.2|172.19.0.3)
			return 1 ;;
	esac
	return 0
}

is_rfc1918() {
	is_ipv4 "$1" || return 1
	case "$1" in
		10.*) return 0 ;;
		192.168.*) return 0 ;;
		172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
	esac
	return 1
}

# Hitch GW must be the on-link ARP next hop, not a transit VPN/CDN address.
is_onlink_gw() {
	local ce="$1" gw="$2"
	is_hitch_ce "$gw" || return 1
	if [ -n "$ce" ] && [ "$gw" = "$ce" ]; then
		return 1
	fi
	if ! is_hitch_ce "$ce"; then
		return 0
	fi
	if is_rfc1918 "$ce"; then
		is_rfc1918 "$gw"
		return $?
	fi
	if is_rfc1918 "$gw"; then
		return 1
	fi
	return 0
}

# Comma-separated IPv4 addresses on an iface (no prefix). Bypass DNS pointed
# at the WAN IP must skip redirect; inet `fib daddr type local` may not match.
list_iface_ipv4_csv() {
	local dev="$1" addr csv=""
	[ -n "$dev" ] || return 0
	for addr in $(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}'); do
		addr="${addr%%/*}"
		is_ipv4 "$addr" || continue
		[ "$addr" = "127.0.0.1" ] && continue
		if [ -n "$csv" ]; then
			csv="$csv, $addr"
		else
			csv="$addr"
		fi
	done
	echo "$csv"
}

LAN_CIDR="${GFC_LAN_CIDR:-$(network_cidr "$LAN_ADDR" "$(mask_prefix "$LAN_MASK")")}"
CN_LIST="${GFC_CN_IP_LIST:-$GFC_ROOT/share/easymosdns/rules/china_ip_list.txt}"
[ -f "$CN_LIST" ] || CN_LIST="$GFC_ETC/rules/china_ip_list.txt"
[ -f "$CN_LIST" ] || CN_LIST="$GFC_ROOT/share/easymosdns/rules/china_ip_list.txt"

# Stock OpenWrt dnsmasq dns_redirect installs table inet dnsmasq (priority -95).
# With port=0 that becomes redirect to :0 (UDP/53 blackhole). Not a GFC table.
purge_dnsmasq_dns_hijack() {
	nft delete table inet dnsmasq 2>/dev/null || true
}

stop_proxy_only() {
	_clear_fwmark_rules
	ip -4 route flush table "$TABLE" 2>/dev/null || true
	nft delete table inet gfc 2>/dev/null || true
	nft delete table inet gfc_client_mangle 2>/dev/null || true
	[ -x "$GFC_ROOT/deploy/apply-tc-htb.sh" ] && sh "$GFC_ROOT/deploy/apply-tc-htb.sh" remove 2>/dev/null || true
}

start_direct() {
	stop_proxy_only
	_fw4_sh="${GFC_ROOT}/deploy/immortalwrt/disable-immortalwrt-fw4.sh"
	[ -f "$_fw4_sh" ] && sh "$_fw4_sh" 2>/dev/null || true
	nft delete table inet gfc_dns_hijack 2>/dev/null || true
	nft delete table inet nat 2>/dev/null || true
	purge_dnsmasq_dns_hijack
	apply_wan_nat
	apply_dns_hijack
	echo "gfc routing: direct mode (dns hijack + snat, proxy disabled)"
}

stop_rules() {
	_clear_fwmark_rules
	ip -4 route flush table "$TABLE" 2>/dev/null || true
	nft delete table inet gfc 2>/dev/null || true
	nft delete table inet gfc_client_mangle 2>/dev/null || true
	nft delete table inet gfc_dns_hijack 2>/dev/null || true
	nft delete table inet nat 2>/dev/null || true
	nft delete table netdev gfc_trans 2>/dev/null || true
	[ -x "$GFC_ROOT/deploy/apply-tc-htb.sh" ] && sh "$GFC_ROOT/deploy/apply-tc-htb.sh" remove 2>/dev/null || true
}

# Remove every fwmark→table rule (hotplug + sing-box post-start can leave duplicates).
_clear_fwmark_rules() {
	local i=0
	while [ "$i" -lt 16 ]; do
		if ip -4 rule del pref 100 fwmark "$MARK" lookup "$TABLE" 2>/dev/null; then
			i=$((i + 1))
			continue
		fi
		if ip -4 rule del fwmark "$MARK" lookup "$TABLE" 2>/dev/null; then
			i=$((i + 1))
			continue
		fi
		if ip -4 rule del fwmark "$MARK" table "$TABLE" 2>/dev/null; then
			i=$((i + 1))
			continue
		fi
		break
	done
}

apply_wan_nat() {
	local proxy_mode masq_match isp ce
	proxy_mode="$(load_proxy_mode)"
	nft delete table inet nat 2>/dev/null || true
	masq_match="    oifname \"$WAN_IFACE\" masquerade"
	if [ "$proxy_mode" = "bypass" ]; then
		masq_match="    oifname \"$WAN_IFACE\" ip saddr $LAN_CIDR masquerade"
	elif [ "$proxy_mode" = "transparent" ]; then
		isp="$(load_trans_isp)"
		ce="$(load_trans_ce)"
		masq_match=""
		# Hitch SNAT only. DNS trampoline SNAT is inserted afterwards so a
		# `ct original ip daddr` syntax miss cannot wipe inet nat (set -e).
		if is_hitch_ce "$ce"; then
			if [ -n "$isp" ]; then
				masq_match="    oifname \"$isp\" snat to $ce"
			fi
			if ip link show br-trans >/dev/null 2>&1; then
				masq_match="$masq_match
    oifname \"br-trans\" ip saddr != $ce snat to $ce"
			fi
		fi
		[ -n "$masq_match" ] || masq_match="    ip saddr $LAN_CIDR accept"
	fi
	nft -f - <<EOF
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$masq_match
  }
}
EOF
	if [ "$proxy_mode" = "transparent" ]; then
		apply_trans_dns_snat || true
	fi
}

# DNS replies must keep the resolver the client asked (NFT §9.4). Insert at head
# so hitch SNAT on br-trans does not rewrite sport 53 first. Never fail the table.
apply_trans_dns_snat() {
	local cpe proto oif
	cpe="$(load_trans_cpe)"
	[ -n "$cpe" ] || return 0
	for proto in udp tcp; do
		for oif in "$cpe" br-trans; do
			ip link show "$oif" >/dev/null 2>&1 || continue
			if nft insert rule inet nat postrouting meta nfproto ipv4 oifname "$oif" "$proto" sport 53 snat ip to ct original ip daddr 2>/dev/null; then
				continue
			fi
			if nft insert rule inet nat postrouting oifname "$oif" "$proto" sport 53 snat to ct original ip daddr 2>/dev/null; then
				continue
			fi
			echo "WARN: transparent DNS trampoline SNAT $proto oif $oif not applied" >&2
		done
	done
	return 0
}

apply_dns_hijack() {
	local proxy_mode hosts wan_rules set_block wan_local wan_ips hijack lan_rules trans_rules vip exclude exclude_set
	proxy_mode="$(load_proxy_mode)"
	hijack="$(load_dns_hijack)"
	hosts="$(load_customer_host_elements)"
	wan_rules=""
	set_block=""
	lan_rules=""
	trans_rules=""
	if [ "$hijack" = "on" ]; then
		lan_rules="
    iifname \"$LAN_IFACE\" udp dport 53 redirect to :$DNS_PORT
    iifname \"$LAN_IFACE\" tcp dport 53 redirect to :$DNS_PORT"
	elif [ "$proxy_mode" = "bypass" ]; then
		# Bypass+off: keep LAN mini-gateway hijack; drop WAN customer steal.
		lan_rules="
    iifname \"$LAN_IFACE\" udp dport 53 redirect to :$DNS_PORT
    iifname \"$LAN_IFACE\" tcp dport 53 redirect to :$DNS_PORT"
	fi
	if [ "$proxy_mode" = "bypass" ] && [ "$hijack" = "on" ]; then
		if [ -n "$hosts" ]; then
			set_block="
  set customer_hosts {
    type ipv4_addr
    flags interval
    elements = { $hosts }
  }"
		else
			set_block="
  set customer_hosts {
    type ipv4_addr
    flags interval
  }"
		fi
		wan_local=""
		wan_ips="$(list_iface_ipv4_csv "$WAN_IFACE")"
		if [ -n "$wan_ips" ]; then
			wan_local="
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts udp dport 53 ip daddr { $wan_ips } return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts tcp dport 53 ip daddr { $wan_ips } return"
		fi
		wan_rules="$wan_local
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts udp dport 53 meta nfproto ipv4 fib daddr . iif type local return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts tcp dport 53 meta nfproto ipv4 fib daddr . iif type local return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts udp dport 53 redirect to :$DNS_PORT
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts tcp dport 53 redirect to :$DNS_PORT"
	fi
	if [ "$proxy_mode" = "transparent" ]; then
		vip="$(load_dns_vip)"
		exclude="$(load_dns_exclude_elements)"
		exclude_set=""
		if [ -n "$exclude" ]; then
			exclude_set="
  set dns_exclude {
    type ipv4_addr
    flags interval
    elements = { $exclude }
  }"
		else
			exclude_set="
  set dns_exclude {
    type ipv4_addr
    flags interval
  }"
		fi
		set_block="$exclude_set"
		trans_rules="
    iifname \"gfc-ce\" udp dport 53 ip daddr $vip return
    iifname \"gfc-ce\" tcp dport 53 ip daddr $vip return
    iifname \"gfc-ce\" udp dport 53 ip daddr @dns_exclude return
    iifname \"gfc-ce\" tcp dport 53 ip daddr @dns_exclude return"
		if [ "$hijack" = "on" ]; then
			trans_rules="$trans_rules
    iifname \"gfc-ce\" udp dport 53 dnat to $vip
    iifname \"gfc-ce\" tcp dport 53 dnat to $vip"
		fi
	fi
	nft -f - <<EOF
table inet gfc_dns_hijack {$set_block
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;$lan_rules$wan_rules$trans_rules
  }
}
EOF
	purge_dnsmasq_dns_hijack
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

load_routing_mode() {
	local mode="split"
	local f="${GFC_ETC}/routing-mode.json"
	if [ -f "$f" ]; then
		if command -v jsonfilter >/dev/null 2>&1; then
			mode="$(jsonfilter -i "$f" -e '@.mode' 2>/dev/null || echo split)"
		else
			mode="$(awk -F'"' '/"mode"[[:space:]]*:/ { print tolower($4); exit }' "$f" 2>/dev/null || echo split)"
		fi
	fi
	mode="$(echo "$mode" | tr 'A-Z' 'a-z')"
	case "$mode" in
		global) echo "global" ;;
		*) echo "split" ;;
	esac
}

load_proxy_mode() {
	local env_mode file_mode f
	env_mode="$(echo "${GFC_PROXY_MODE:-}" | tr 'A-Z' 'a-z')"
	file_mode=""
	f="${GFC_ETC}/proxy-mode.json"
	if [ -f "$f" ]; then
		if command -v jsonfilter >/dev/null 2>&1; then
			file_mode="$(jsonfilter -i "$f" -e '@.mode' 2>/dev/null || true)"
		else
			file_mode="$(awk -F'"' '/"mode"[[:space:]]*:/ { print tolower($4); exit }' "$f" 2>/dev/null || true)"
		fi
		file_mode="$(echo "$file_mode" | tr 'A-Z' 'a-z')"
	fi
	# Pending switch writes env first and only commits proxy-mode.json on confirm.
	# Env must win so leaving bypass/transparent actually applies gateway nft.
	case "$env_mode" in
		gateway|bypass|transparent) echo "$env_mode"; return 0 ;;
	esac
	case "$file_mode" in
		gateway|bypass|transparent) echo "$file_mode"; return 0 ;;
	esac
	echo "gateway"
}

load_customer_host_elements() {
	local f="${GFC_ETC}/customer-hosts.json"
	local out="" token
	[ -f "$f" ] || { echo ""; return 0; }
	for token in $(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' "$f" 2>/dev/null || true); do
		[ -n "$token" ] || continue
		is_ipv4 "${token%%/*}" || continue
		[ -n "$out" ] && out="$out, "
		out="${out}${token}"
	done
	echo "$out"
}

json_get() {
	local f="$1" key="$2"
	[ -f "$f" ] || return 0
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$f" -e "@.$key" 2>/dev/null || true
	else
		awk -F'"' -v k="$key" '
			$0 ~ "\"" k "\"" {
				for (i = 1; i <= NF; i++) if ($i == k && $(i+2) != "") { print $(i+2); exit }
			}
		' "$f" 2>/dev/null || true
	fi
}

load_dns_hijack() {
	local f="${GFC_ETC}/dns-hijack.json" v
	v="$(json_get "$f" enabled | tr 'A-Z' 'a-z')"
	case "$v" in
		false|0|off|no) echo "off" ;;
		*) echo "on" ;;
	esac
}

load_dns_vip() {
	local f="${GFC_ETC}/dns-hijack.json" v
	v="$(json_get "$f" vip)"
	is_ipv4 "$v" && echo "$v" || echo "172.31.253.53"
}

load_dns_exclude_elements() {
	local f="${GFC_ETC}/dns-hijack.json"
	local out="" token vip
	vip="$(load_dns_vip)"
	[ -f "$f" ] || { echo ""; return 0; }
	for token in $(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?' "$f" 2>/dev/null || true); do
		[ -n "$token" ] || continue
		is_ipv4 "${token%%/*}" || continue
		[ "${token%%/*}" = "$vip" ] && continue
		[ -n "$out" ] && out="$out, "
		out="${out}${token}"
	done
	echo "$out"
}

load_trans_isp() { json_get "${GFC_ETC}/transparent-ports.json" isp_port; }
load_trans_cpe() { json_get "${GFC_ETC}/transparent-ports.json" cpe_port; }
load_trans_ce() { json_get "${GFC_ETC}/transparent-learned.json" ce_ip; }
load_trans_gw() { json_get "${GFC_ETC}/transparent-learned.json" gw_ip; }
load_trans_cpe_mac() { json_get "${GFC_ETC}/transparent-learned.json" cpe_mac; }
load_trans_pe_mac() { json_get "${GFC_ETC}/transparent-learned.json" pe_mac; }

hw_mac() {
	local dev="$1"
	[ -n "$dev" ] && [ -f "/sys/class/net/$dev/address" ] && cat "/sys/class/net/$dev/address" || true
}

wan_if_is_trans_port() {
	local wan isp cpe
	wan="$WAN_IFACE"
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	[ -n "$wan" ] || return 1
	[ "$wan" = "$isp" ] || [ "$wan" = "$cpe" ]
}

# Stop netifd from putting an IP on isp/cpe while they are br-trans slaves.
release_wan_from_netifd() {
	wan_if_is_trans_port || return 0
	ifdown wan 2>/dev/null || true
	if command -v uci >/dev/null 2>&1; then
		uci -q set network.wan.auto='0'
		uci -q commit network
	fi
}

restore_wan_uci_auto() {
	command -v uci >/dev/null 2>&1 || return 0
	local changed=0
	if [ "$(uci -q get network.wan.auto 2>/dev/null || true)" = "0" ]; then
		uci -q delete network.wan.auto
		changed=1
	fi
	if [ "$(uci -q get network.wan.disabled 2>/dev/null || true)" = "1" ]; then
		uci -q delete network.wan.disabled
		changed=1
	fi
	# Must not be `[ x ] && commit` — under set -e that returns 1 when unchanged
	# and aborts start_rules after stop_rules already deleted inet nat/gfc.
	if [ "$changed" = "1" ]; then
		uci -q commit network || true
	fi
	return 0
}

restore_gateway_sysctl() {
	# Stock forwarding default. Do not re-enable bridge-nf (transparent contract).
	sysctl -w net.ipv4.ip_nonlocal_bind=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null 2>&1 || true
	local isp cpe dev
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	for dev in "$isp" "$cpe" "$WAN_IFACE"; do
		[ -n "$dev" ] || continue
		[ -d "/sys/class/net/$dev" ] || continue
		sysctl -w "net.ipv4.conf.${dev}.rp_filter=0" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_ignore=0" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_announce=0" >/dev/null 2>&1 || true
	done
}

teardown_trans_bridge() {
	local isp cpe
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	nft delete table netdev gfc_trans 2>/dev/null || true
	# Gateway/bypass start always calls this. Leftover transparent-ports.json
	# (e.g. isp_port=eth0) must not nomaster the live WAN when br-trans is gone.
	if ! ip link show br-trans >/dev/null 2>&1 && ! ip link show gfc-ce >/dev/null 2>&1; then
		restore_gateway_sysctl
		restore_wan_uci_auto
		return 0
	fi
	if [ -n "$isp" ]; then
		ip link set "$isp" nomaster 2>/dev/null || true
		ip link set "$isp" promisc off 2>/dev/null || true
	fi
	if [ -n "$cpe" ]; then
		ip link set "$cpe" nomaster 2>/dev/null || true
		ip link set "$cpe" promisc off 2>/dev/null || true
	fi
	del_trans_dev br-trans
	del_trans_dev gfc-ce
	del_trans_dev gfc-dns
	restore_gateway_sysctl
	restore_wan_uci_auto
}

del_trans_dev() {
	local d="$1"
	[ -n "$d" ] || return 0
	ip link show "$d" >/dev/null 2>&1 || return 0
	ip link set "$d" down 2>/dev/null || true
	if command -v timeout >/dev/null 2>&1; then
		timeout 2 ip link del "$d" 2>/dev/null || true
	else
		ip link del "$d" 2>/dev/null || true
	fi
}

# gfc-ce / gfc-dns: dummy if kmod-dummy is present, else an empty bridge so
# netdev `fwd to` still has a target. Silent `|| true` hid missing kmod-dummy.
ensure_dummy() {
	local name="$1"
	[ -n "$name" ] || return 1
	modprobe dummy 2>/dev/null || true
	if ip link show "$name" >/dev/null 2>&1; then
		ip link set "$name" up 2>/dev/null || true
		ip link set "$name" arp off 2>/dev/null || true
		return 0
	fi
	if ip link add "$name" type dummy 2>/dev/null; then
		echo "transparent: $name type dummy"
	elif ip link add "$name" type bridge 2>/dev/null; then
		echo "WARN: kmod-dummy missing; $name is an empty bridge (nft fwd target)" >&2
	else
		echo "ERROR: cannot create $name (need kmod-dummy)" >&2
		return 1
	fi
	ip link set "$name" up 2>/dev/null || return 1
	ip link set "$name" arp off 2>/dev/null || true
	return 0
}

# Slaves cannot carry L3 routes. Hitch default / CE on-link use br-trans.
trans_l3_dev() {
	if ip link show br-trans >/dev/null 2>&1; then
		echo "br-trans"
		return 0
	fi
	load_trans_isp
}

apply_trans_sysctl() {
	local isp cpe
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.ip_nonlocal_bind=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-ip6tables=0 >/dev/null 2>&1 || true
	sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null 2>&1 || true
	for dev in "$isp" "$cpe" br-trans gfc-ce gfc-dns; do
		[ -n "$dev" ] || continue
		sysctl -w "net.ipv4.conf.${dev}.rp_filter=2" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_ignore=2" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_announce=2" >/dev/null 2>&1 || true
	done
}

apply_trans_bridge() {
	local isp cpe
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	if [ -z "$isp" ] || [ -z "$cpe" ] || [ "$isp" = "$cpe" ]; then
		echo "WARN: transparent ports missing; skip br-trans" >&2
		return 1
	fi
	if [ "$isp" = "$LAN_IFACE" ] || [ "$cpe" = "$LAN_IFACE" ]; then
		echo "WARN: isp/cpe must not be management LAN $LAN_IFACE" >&2
		return 1
	fi
	if [ -d "/sys/class/net/$LAN_IFACE/brif/$isp" ] || [ -d "/sys/class/net/$LAN_IFACE/brif/$cpe" ]; then
		echo "WARN: isp/cpe must not be a $LAN_IFACE bridge port" >&2
		return 1
	fi
	release_wan_from_netifd
	modprobe dummy 2>/dev/null || true
	ensure_dummy gfc-ce || echo "WARN: gfc-ce missing; netdev fwd will fail-open" >&2
	ensure_dummy gfc-dns || echo "WARN: gfc-dns missing; DNS VIP not mounted" >&2
	ip link show br-trans >/dev/null 2>&1 || ip link add name br-trans type bridge 2>/dev/null || true
	ip link set "$isp" nomaster 2>/dev/null || true
	ip link set "$cpe" nomaster 2>/dev/null || true
	ip addr flush dev "$isp" 2>/dev/null || true
	ip addr flush dev "$cpe" 2>/dev/null || true
	ip link set "$isp" master br-trans 2>/dev/null || true
	ip link set "$cpe" master br-trans 2>/dev/null || true
	ip link set "$isp" up 2>/dev/null || true
	ip link set "$cpe" up 2>/dev/null || true
	ip link set "$isp" promisc on 2>/dev/null || true
	ip link set "$cpe" promisc on 2>/dev/null || true
	ip link set br-trans up 2>/dev/null || true
	ip addr flush dev br-trans 2>/dev/null || true
	echo "transparent bridge: br-trans slaves $isp + $cpe (lan=$LAN_IFACE excluded)"
}

apply_trans_addrs() {
	local vip ce gw isp cpe cpe_mac pe_mac l3 def need_hitch
	vip="$(load_dns_vip)"
	ce="$(load_trans_ce)"
	gw="$(load_trans_gw)"
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	cpe_mac="$(load_trans_cpe_mac)"
	pe_mac="$(load_trans_pe_mac)"
	l3="$(trans_l3_dev)"
	ip addr replace 172.31.253.1/32 dev gfc-ce 2>/dev/null || true
	ip addr replace "$vip/32" dev gfc-dns 2>/dev/null || true
	if is_hitch_ce "$ce"; then
		ip addr replace "$ce/32" dev gfc-ce noprefixroute 2>/dev/null || true
		ip route del table local "$ce/32" 2>/dev/null || true
		# Do not route via the enslaved cpe port — L3 must use br-trans.
		if [ -n "$l3" ]; then
			ip route replace "$ce/32" dev "$l3" 2>/dev/null || true
			if [ -n "$cpe_mac" ]; then
				ip neigh replace "$ce" lladdr "$cpe_mac" nud permanent dev "$l3" 2>/dev/null || true
			fi
		fi
		if [ -n "$cpe" ] && [ -n "$cpe_mac" ]; then
			bridge fdb replace "$cpe_mac" dev "$cpe" master static 2>/dev/null || true
		fi
	else
		# Drop stale APIPA/leftover CE so we do not hitch 169.254.
		ce=""
		ip -4 addr show dev gfc-ce 2>/dev/null | awk '/inet 169.254\./ { print $2 }' | while read -r a; do
			ip addr del "$a" dev gfc-ce 2>/dev/null || true
		done
	fi
	# Drop leftover host routes on br-trans (APIPA, VPN server mistaken as GW).
	if [ -n "$l3" ]; then
		ip -4 route show dev "$l3" 2>/dev/null | awk '{print $1}' | while read -r dest; do
			[ -n "$dest" ] || continue
			if [ "$dest" = "default" ]; then
				continue
			fi
			if [ "$dest" = "$ce" ] || [ "$dest" = "$ce/32" ]; then
				continue
			fi
			if is_onlink_gw "$ce" "$gw"; then
				if [ "$dest" = "$gw" ] || [ "$dest" = "$gw/32" ]; then
					continue
				fi
			fi
			ip route del "$dest" dev "$l3" 2>/dev/null || true
		done
	fi
	if is_onlink_gw "$ce" "$gw" && [ -n "$l3" ]; then
		if [ -n "$pe_mac" ]; then
			ip neigh replace "$gw" lladdr "$pe_mac" nud permanent dev "$l3" 2>/dev/null || true
			if [ -n "$isp" ]; then
				bridge fdb replace "$pe_mac" dev "$isp" master static 2>/dev/null || true
			fi
		fi
		# Learned hosts only — GW is not on a connected prefix. `onlink` is mandatory.
		ip route replace "$gw/32" dev "$l3" 2>/dev/null || true
		# Hitch default when main has none, leftover APIPA, or an existing br-trans
		# default. Never replace another iface's default (management WAN).
		# Do not use `src $ce`: CE /32 is removed from local table so the box
		# does not ARP as CE; hitch SNAT supplies the CE source.
		def="$(ip -4 route show default 2>/dev/null | head -1 || true)"
		need_hitch=0
		if [ -z "$def" ]; then
			need_hitch=1
		fi
		if echo "$def" | grep -q '169\.254\.'; then
			need_hitch=1
		fi
		if echo "$def" | grep -q " dev $l3"; then
			need_hitch=1
		fi
		if [ "$need_hitch" -eq 1 ]; then
			if echo "$def" | grep -q '169\.254\.'; then
				ip route del default 2>/dev/null || true
			fi
			ip route replace default via "$gw" dev "$l3" onlink 2>/dev/null || \
				ip route replace default via "$gw" dev "$l3" 2>/dev/null || true
		fi
	fi
}

apply_trans_netdev() {
	local isp cpe vip hijack tun_up exclude no_steal ce gw
	local isp_mac cpe_hw learned_cpe_mac pe_mac
	local dns_vip_rules dns_steal tcp_steal mac_isp mac_cpe hitch_upd exclude_set
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	vip="$(load_dns_vip)"
	hijack="$(load_dns_hijack)"
	exclude="$(load_dns_exclude_elements)"
	isp_mac="$(hw_mac "$isp")"
	cpe_hw="$(hw_mac "$cpe")"
	learned_cpe_mac="$(load_trans_cpe_mac)"
	pe_mac="$(load_trans_pe_mac)"
	[ -n "$isp" ] && [ -n "$cpe" ] || return 1
	modprobe nft_fwd_netdev 2>/dev/null || true
	modprobe nft-fwd-netdev 2>/dev/null || true
	if ! ip link show gfc-ce >/dev/null 2>&1; then
		echo "WARN: gfc-ce missing; skip netdev gfc_trans (L2 fail-open)" >&2
		return 1
	fi
	nft delete table netdev gfc_trans 2>/dev/null || true
	tun_up=0
	ip link show "$TUN_IFACE" >/dev/null 2>&1 && tun_up=1
	no_steal="10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
	ce="$(load_trans_ce)"
	gw="$(load_trans_gw)"
	if is_hitch_ce "$ce"; then
		no_steal="$no_steal, $ce"
	fi
	if is_onlink_gw "$ce" "$gw"; then
		no_steal="$no_steal, $gw"
	fi
	dns_vip_rules="
    udp dport 53 ip daddr $vip fwd to \"gfc-ce\"
    tcp dport 53 ip daddr $vip fwd to \"gfc-ce\""
	dns_steal=""
	if [ "$hijack" = "on" ] && [ "$tun_up" -eq 1 ]; then
		if [ -n "$exclude" ]; then
			dns_steal="
    udp dport 53 ip daddr @dns_exclude accept
    tcp dport 53 ip daddr @dns_exclude accept"
		fi
		dns_steal="$dns_steal
    udp dport 53 fwd to \"gfc-ce\"
    tcp dport 53 fwd to \"gfc-ce\""
	fi
	tcp_steal=""
	if [ "$tun_up" -eq 1 ]; then
		tcp_steal="
    ip daddr @no_steal_dst accept
    meta l4proto tcp fwd to \"gfc-ce\""
	fi
	mac_isp=""
	hitch_upd=""
	if [ -n "$isp_mac" ] && [ -n "$learned_cpe_mac" ] && [ -n "$pe_mac" ]; then
		hitch_upd="
    ether saddr $isp_mac meta l4proto { tcp, udp } update @hitch_reply { meta l4proto . ip daddr . th dport . ip saddr . th sport timeout 2m }"
		mac_isp="
    ether saddr $isp_mac ether saddr set $learned_cpe_mac ether daddr set $pe_mac"
	fi
	mac_cpe=""
	if [ -n "$cpe_hw" ] && [ -n "$pe_mac" ]; then
		mac_cpe="
    ether saddr $cpe_hw ether saddr set $pe_mac"
	fi
	exclude_set=""
	if [ -n "$exclude" ]; then
		exclude_set="
    elements = { $exclude }"
	fi
	if ! nft -f - <<EOF
table netdev gfc_trans {
  set hitch_reply {
    type inet_proto . ipv4_addr . inet_service . ipv4_addr . inet_service
    timeout 2m
    size 65536
    flags dynamic,timeout
  }
  set no_steal_dst {
    type ipv4_addr
    flags interval
    elements = { $no_steal }
  }
  set dns_exclude {
    type ipv4_addr
    flags interval$exclude_set
  }
  chain in_isp {
    type filter hook ingress device "$isp" priority -500; policy accept;
    meta l4proto { tcp, udp } meta l4proto . ip saddr . th sport . ip daddr . th dport @hitch_reply fwd to "gfc-ce"
  }
  chain in_cpe {
    type filter hook ingress device "$cpe" priority -500; policy accept;
    ether type 8021q accept
    ether type ip6 accept
    ether type 0x8863 accept
    ether type 0x8864 accept
    ether type != ip accept
    ip protocol { 4, 47, 50, 51, 115 } accept
    udp dport { 500, 4500, 1701 } accept
$dns_vip_rules
$dns_steal
$tcp_steal
  }
  chain eg_isp {
    type filter hook egress device "$isp" priority 0; policy accept;
$hitch_upd
$mac_isp
  }
  chain eg_cpe {
    type filter hook egress device "$cpe" priority 0; policy accept;
$mac_cpe
  }
}
EOF
	then
		echo "WARN: nft netdev gfc_trans failed (need kmod-nft-netdev / nft_fwd_netdev)" >&2
		return 1
	fi
	if ! nft list table netdev gfc_trans >/dev/null 2>&1; then
		echo "WARN: netdev gfc_trans missing after load (need kmod-nft-netdev)" >&2
		return 1
	fi
	fill_netdev_no_steal
	echo "transparent netdev gfc_trans: isp=$isp cpe=$cpe hijack=$hijack tun=$tun_up vip=$vip"
}

fill_netdev_no_steal() {
	local tmp
	tmp="$(mktemp)" || return 0
	{
		nft list set inet gfc bypass_ip 2>/dev/null | awk '
			BEGIN{ins=0}
			/elements/ {ins=1}
			ins {
				while (match($0, /([0-9]+\.){3}[0-9]+(\/[0-9]+)?/)) {
					print substr($0, RSTART, RLENGTH)
					$0 = substr($0, RSTART+RLENGTH)
				}
			}
		'
		if [ "$(load_routing_mode)" != "global" ] && [ -f "$CN_LIST" ]; then
			awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/ { print $1 }' "$CN_LIST"
		fi
	} | awk 'BEGIN{n=0; started=0}
		NF && $1 !~ /^$/ {
			if (!started) { printf "add element netdev gfc_trans no_steal_dst { "; started=1; }
			if (n > 0) printf ", ";
			printf "%s", $1;
			n++;
			if (n == 200) { print " }"; n=0; started=0; }
		}
		END{ if (started) print " }"; }' > "$tmp"
	if [ -s "$tmp" ]; then
		nft -f "$tmp" 2>/dev/null || true
	fi
	rm -f "$tmp"
}

refresh_trans() {
	[ "$(load_proxy_mode)" = "transparent" ] || return 0
	ensure_dummy gfc-ce || echo "WARN: gfc-ce missing; netdev fwd will fail-open" >&2
	ensure_dummy gfc-dns || echo "WARN: gfc-dns missing" >&2
	apply_trans_sysctl
	apply_trans_addrs
	# Learning often completes after start_rules; hitch SNAT must follow CE.
	apply_wan_nat || echo "WARN: hitch NAT refresh failed" >&2
	apply_trans_netdev || echo "WARN: netdev gfc_trans refresh failed (L2 fail-open)" >&2
	write_bypass_unbound_acl
}

apply_bypass_sysctl() {
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
	if [ -n "$WAN_IFACE" ]; then
		sysctl -w "net.ipv4.conf.${WAN_IFACE}.rp_filter=2" >/dev/null 2>&1 || true
	fi
}

# Unbound ACL for @customer_hosts (may be public). Must exist: main conf includes this file.
write_bypass_unbound_acl() {
	local dest="/etc/unbound/conf.d/gfc-bypass-acl.conf"
	local tmp token net need_restart=0
	mkdir -p /etc/unbound/conf.d
	tmp="${dest}.tmp.$$"
	{
		echo "# Generated by gfc-routing.sh — do not edit"
		echo "# Extra ACL: bypass customer_hosts or transparent learned CE. Never 0.0.0.0/0."
		if [ "$(load_proxy_mode)" = "bypass" ]; then
			for token in $(load_customer_host_elements | tr ',' ' '); do
				token="$(echo "$token" | tr -d '[:space:]')"
				[ -n "$token" ] || continue
				[ "$token" = "0.0.0.0/0" ] && continue
				case "$token" in
					*/*) net="$token" ;;
					*) net="$token/32" ;;
				esac
				echo "    access-control: $net allow"
			done
		fi
		if [ "$(load_proxy_mode)" = "transparent" ]; then
			ce="$(load_trans_ce)"
			if is_hitch_ce "$ce"; then
				echo "    access-control: $ce/32 allow"
			fi
		fi
	} > "$tmp"
	need_restart=0
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
	else
		mv "$tmp" "$dest"
		chmod 644 "$dest" 2>/dev/null || true
		need_restart=1
	fi
	if [ -f /etc/unbound/unbound.conf ] && ! grep -q 'gfc-bypass-acl.conf' /etc/unbound/unbound.conf; then
		ensure_unbound_bypass_include
		need_restart=1
	fi
	if [ "$need_restart" -eq 1 ]; then
		if command -v unbound-control >/dev/null 2>&1 && unbound-control reload >/dev/null 2>&1; then
			echo "unbound ACL reloaded ($dest)"
		elif [ -x /etc/init.d/gfc-unbound ]; then
			/etc/init.d/gfc-unbound restart >/dev/null 2>&1 || true
			echo "unbound bypass ACL updated ($dest)"
		fi
	fi
}

# OTA may still have unbound.conf without the include; insert after last access-control.
ensure_unbound_bypass_include() {
	local conf="/etc/unbound/unbound.conf"
	local tmp
	[ -f "$conf" ] || return 0
	grep -q 'gfc-bypass-acl.conf' "$conf" && return 0
	tmp="${conf}.tmp.$$"
	awk '
		{ lines[NR] = $0 }
		$0 ~ /access-control:/ { last = NR }
		END {
			if (last == 0) {
				for (i = 1; i <= NR; i++) print lines[i]
				exit
			}
			for (i = 1; i <= NR; i++) {
				print lines[i]
				if (i == last)
					print "    include: \"/etc/unbound/conf.d/gfc-bypass-acl.conf\""
			}
		}
	' "$conf" > "$tmp" && mv "$tmp" "$conf"
}

apply_policy_table_architecture() {
	local ext_const routing_mode proxy_mode hosts ce
	local cn_preroute_rule cn_output_rule cn_wan_rule output_customer_rule
	local ct_head ct_wan route_head route_wan forward_customer customer_set
	ext_const="$(fmt_ext_const_elements)"
	routing_mode="$(load_routing_mode)"
	proxy_mode="$(load_proxy_mode)"
	hosts="$(load_customer_host_elements)"
	cn_preroute_rule=""
	cn_output_rule=""
	cn_wan_rule=""
	output_customer_rule=""
	ct_head=""
	ct_wan=""
	route_head=""
	route_wan=""
	forward_customer=""
	customer_set=""
	if [ "$routing_mode" != "global" ]; then
		cn_preroute_rule="    iifname \"$LAN_IFACE\" ip daddr @TO_CN return"
		cn_output_rule="    ip daddr @TO_CN return"
	fi
	if [ "$proxy_mode" = "bypass" ]; then
		if [ -n "$hosts" ]; then
			customer_set="
  set customer_hosts {
    type ipv4_addr
    flags interval
    elements = { $hosts }
  }"
		else
			customer_set="
  set customer_hosts {
    type ipv4_addr
    flags interval
  }"
		fi
		ct_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		route_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		ct_wan="    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ct state { established, related } return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ct mark set $MARK accept"
		if [ "$routing_mode" != "global" ]; then
			cn_wan_rule="    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ip daddr @TO_CN return"
		fi
		route_wan="    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ip daddr @customer_hosts return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts udp dport { 53, 67, 68, 123 } return
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ip daddr @bypass_ip return
    # WAN path: user overlay already jumped above (shared chain); system defaults follow
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ip daddr @ext_const ct mark $MARK meta mark set ct mark return
${cn_wan_rule}
    iifname \"$WAN_IFACE\" ip saddr @customer_hosts ct mark $MARK meta mark set ct mark"
		forward_customer="    ct state new ip saddr @customer_hosts ct mark set meta mark"
		output_customer_rule="    ip daddr @customer_hosts return"
	fi
	if [ "$proxy_mode" = "transparent" ]; then
		ct_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		route_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		ct_wan="    iifname \"gfc-ce\" ct mark set $MARK accept"
		if [ "$routing_mode" != "global" ]; then
			cn_wan_rule="    iifname \"gfc-ce\" ip daddr @TO_CN return"
		fi
		route_wan="    iifname \"gfc-ce\" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    iifname \"gfc-ce\" ip daddr $LAN_CIDR return
    iifname \"gfc-ce\" udp dport { 53, 67, 68, 123 } return
    iifname \"gfc-ce\" ip daddr @bypass_ip return
    iifname \"gfc-ce\" ip daddr @ext_const ct mark $MARK meta mark set ct mark return
${cn_wan_rule}
    iifname \"gfc-ce\" ct mark $MARK meta mark set ct mark"
		ce="$(load_trans_ce)"
		if is_hitch_ce "$ce"; then
			forward_customer="    ct state new ip saddr $ce ct mark set meta mark"
			output_customer_rule="    ip daddr $ce return"
		fi
	fi
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
$customer_set
  set ext {
    type ipv4_addr
    size 262144
    timeout 2h
  }

  set ext_const {
    type ipv4_addr
    elements = { $ext_const }
  }

  # User Overlay chains (docs/USER_POLICY_ROUTING.md §7) — rules filled by policy-routing apply
  chain prerouting_user_overlay {
  }

  chain output_user_overlay {
  }

  chain prerouting_mangle_ct {
    type filter hook prerouting priority mangle; policy accept;
$ct_head
    iifname "$LAN_IFACE" ct mark set $MARK accept
$ct_wan
  }

  chain prerouting_mangle_route {
    type filter hook prerouting priority filter; policy accept;
$route_head
    iifname "$LAN_IFACE" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    iifname "$LAN_IFACE" ip daddr $LAN_CIDR return
    iifname "$LAN_IFACE" udp dport { 53, 67, 68, 123 } return
    iifname "$LAN_IFACE" ip daddr @bypass_ip return
    # --- GFC_USER_OVERLAY_BEGIN (after bypass_ip / before system default) ---
    jump prerouting_user_overlay
    # --- GFC_USER_OVERLAY_END ---
    iifname "$LAN_IFACE" ip daddr @ext_const ct mark $MARK meta mark set ct mark return
${cn_preroute_rule}
    iifname "$LAN_IFACE" ct mark $MARK meta mark set ct mark
$route_wan
  }

  chain gfc_forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    ct state new ip saddr $LAN_CIDR ct mark set meta mark
$forward_customer
    accept
  }

  chain output_mangle_route {
    type route hook output priority filter; policy accept;
    meta mark != 0x00000000 return
    tcp dport $SSH_PORT return
    ip daddr @TO_RFC1918 return
    ip daddr 127.0.0.0/8 return
${output_customer_rule}
${cn_output_rule}
    ip daddr @bypass_ip counter return
    # --- GFC_USER_OVERLAY_OUTPUT_BEGIN (after bypass_ip / before catch-all mark) ---
    jump output_user_overlay
    # --- GFC_USER_OVERLAY_OUTPUT_END ---
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

load_user_overlay() {
	# Re-apply device-Web Override after table recreate (docs/USER_POLICY_ROUTING.md).
	local sh="${GFC_ETC}/policy-routing/user-overlay.sh"
	local f="${GFC_ETC}/policy-routing/user-overlay.nft"
	if [ -x "$sh" ]; then
		if sh "$sh"; then
			echo "user overlay: loaded via $sh"
		else
			echo "WARN: user overlay script failed: $sh" >&2
		fi
		return 0
	fi
	if [ ! -f "$f" ]; then
		return 0
	fi
	if nft -f "$f"; then
		echo "user overlay: loaded $f"
	else
		echo "WARN: user overlay load failed: $f" >&2
	fi
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
	local i max="${GFC_ROUTING_TUN_WAIT:-30}"
	# Unactivated OEM: no sing-box.json yet → do not block 30s on every start.
	if [ ! -f "${GFC_ETC}/sing-box.json" ] && [ "$max" -gt 3 ] 2>/dev/null; then
		max=2
	fi
	[ "$max" -gt 0 ] 2>/dev/null || return 1
	for i in $(seq 1 "$max"); do
		ip link show "$TUN_IFACE" >/dev/null 2>&1 && return 0
		sleep 1
	done
	return 1
}

start_rules() {
	stop_rules
	_fw4_sh="${GFC_ROOT}/deploy/immortalwrt/disable-immortalwrt-fw4.sh"
	[ -f "$_fw4_sh" ] && sh "$_fw4_sh" 2>/dev/null || {
		/etc/init.d/firewall stop 2>/dev/null || true
		/etc/init.d/firewall disable 2>/dev/null || true
	}
	purge_dnsmasq_dns_hijack
	if [ "$(load_proxy_mode)" = "transparent" ]; then
		apply_trans_bridge || echo "WARN: br-trans setup failed" >&2
		apply_trans_sysctl
		apply_trans_addrs || echo "WARN: transparent addrs/hitch route failed" >&2
	else
		need_wan=0
		if command -v uci >/dev/null 2>&1 && [ "$(uci -q get network.wan.auto 2>/dev/null || true)" = "0" ]; then
			need_wan=1
		fi
		# stop_rules already deleted inet nat/gfc. Teardown must not abort start.
		teardown_trans_bridge || echo "WARN: teardown_trans_bridge failed; continuing NAT apply" >&2
		if [ "$need_wan" = "1" ]; then
			ifup wan 2>/dev/null || true
		fi
	fi
	apply_wan_nat || echo "WARN: apply_wan_nat failed" >&2
	apply_dns_hijack || echo "WARN: apply_dns_hijack failed" >&2
	apply_policy_table || echo "WARN: apply_policy_table failed" >&2
	apply_output_policy || true
	load_cn_set || true
	load_bypass_set || true
	load_user_overlay || true
	write_bypass_unbound_acl || true
	if [ "$(load_proxy_mode)" = "bypass" ]; then
		apply_bypass_sysctl
	elif [ "$(load_proxy_mode)" != "transparent" ]; then
		restore_gateway_sysctl
	fi
	if [ "$(load_proxy_mode)" = "transparent" ]; then
		apply_trans_netdev || echo "WARN: netdev gfc_trans apply failed; L2 fail-open" >&2
	fi
	wait_tun || {
		echo "WARN: $TUN_IFACE not up; DNS hijack and CN policy set applied, policy route deferred (hotplug 99-gfc-tun will apply when TUN appears)" >&2
		exit 0
	}
	if [ "$(load_proxy_mode)" = "transparent" ]; then
		apply_trans_netdev || echo "WARN: netdev gfc_trans apply failed; L2 fail-open" >&2
	fi
	_clear_fwmark_rules
	ip -4 rule add pref 100 fwmark "$MARK" lookup "$TABLE" || echo "WARN: ip rule add fwmark $MARK failed" >&2
	ip -4 route replace default dev "$TUN_IFACE" table "$TABLE" || echo "WARN: policy table $TABLE default via $TUN_IFACE failed" >&2
	if [ -x "$GFC_ROOT/deploy/apply-tc-htb.sh" ]; then
		sh "$GFC_ROOT/deploy/apply-tc-htb.sh" apply 2>/dev/null || true
	fi
	echo "gfc routing: scheme=$ROUTING_SCHEME proxy=$(load_proxy_mode) mode=$(load_routing_mode) lan=$LAN_IFACE wan=$WAN_IFACE cidr=$LAN_CIDR mark=$MARK table=$TABLE redirect=$REDIRECT_PORT ssh=$SSH_PORT priority=$NFT_PRIORITY output=$OUTPUT_POLICY mosdns_uid=$MOSDNS_UID singbox_uid=$SINGBOX_UID cn=$CN_LIST bypass=$BYPASS_AUDIT"
}

case "$ACTION" in
	start) start_rules ;;
	direct) start_direct ;;
	stop) stop_rules ;;
	restart) stop_rules; start_rules ;;
	refresh-trans) refresh_trans ;;
	leave-trans) teardown_trans_bridge ;;
	status)
		echo "scheme=$ROUTING_SCHEME proxy=$(load_proxy_mode) lan=$LAN_IFACE wan=$WAN_IFACE cidr=$LAN_CIDR tun=$TUN_IFACE mark=$MARK table=$TABLE redirect=$REDIRECT_PORT ssh=$SSH_PORT"
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
		if [ "$(load_proxy_mode)" = "transparent" ]; then
			echo "trans_ports isp=$(load_trans_isp) cpe=$(load_trans_cpe)"
			echo "trans_learned ce=$(load_trans_ce) gw=$(load_trans_gw) cpe_mac=$(load_trans_cpe_mac) pe_mac=$(load_trans_pe_mac)"
			echo "gfc-ce=$(ip link show gfc-ce >/dev/null 2>&1 && echo yes || echo no) gfc-dns=$(ip link show gfc-dns >/dev/null 2>&1 && echo yes || echo no)"
			echo "gfc_trans=$(nft list table netdev gfc_trans >/dev/null 2>&1 && echo yes || echo no)"
			echo "default=$(ip -4 route show default 2>/dev/null | head -1)"
			echo "modules=$(lsmod 2>/dev/null | awk '/dummy|nft_fwd|nft_netdev/ { printf \"%s \", $1 }')"
		fi
		;;
	*) echo "usage: $0 {start|direct|stop|restart|status|refresh-trans|leave-trans}" >&2; exit 2 ;;
esac
