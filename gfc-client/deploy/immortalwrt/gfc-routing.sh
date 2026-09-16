#!/bin/sh
set -eu

ACTION="${1:-start}"
ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

acquire_action_lock() {
	case "$ACTION" in
		status) return 0 ;;
	esac
	local lock_file="${GFC_ROUTING_LOCK_FILE:-/var/run/gfc-routing.lock}"
	mkdir -p "$(dirname "$lock_file")"
	if command -v flock >/dev/null 2>&1; then
		exec 9>"$lock_file"
		local flock_tries=0
		while ! flock -n 9; do
			flock_tries=$((flock_tries + 1))
			if [ "$flock_tries" -ge "${GFC_ROUTING_LOCK_WAIT:-30}" ]; then
				echo "ERROR: timed out waiting for gfc-routing lock ($ACTION)" >&2
				exit 1
			fi
			sleep 1
		done
		return 0
	fi

	# Minimal fallback for images without flock. The PID check reclaims a lock
	# left by an interrupted apply; EXIT releases a normally held lock.
	ROUTING_LOCK_DIR="${lock_file}.d"
	local tries=0 holder=""
	while ! mkdir "$ROUTING_LOCK_DIR" 2>/dev/null; do
		holder="$(cat "$ROUTING_LOCK_DIR/pid" 2>/dev/null || true)"
		if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
			rm -rf "$ROUTING_LOCK_DIR"
			continue
		fi
		tries=$((tries + 1))
		if [ "$tries" -ge "${GFC_ROUTING_LOCK_WAIT:-30}" ]; then
			echo "ERROR: timed out waiting for gfc-routing lock ($ACTION, pid=$holder)" >&2
			exit 1
		fi
		sleep 1
	done
	echo "$$" >"$ROUTING_LOCK_DIR/pid"
	trap 'rm -rf "$ROUTING_LOCK_DIR"' EXIT
	trap 'exit 130' HUP INT TERM
}

TUN_IFACE="${GFC_TUN_INTERFACE:-gfctun}"
PUNT_IFB="${GFC_PUNT_IFB:-gfc-punt}"
PUNT_MACVLAN="${GFC_PUNT_MACVLAN:-gfc-rx}"
WAN_IFACE="${GFC_WAN_IFACE:-eth0}"
MARK="${GFC_POLICY_MARK:-0x2023}"
TABLE="${GFC_POLICY_TABLE:-2022}"
BYPASS_RULE_PREF="${GFC_BYPASS_RULE_PREF:-90}"
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

# nft interval sets reject a host that already sits inside a listed prefix.
# RFC1918 CE/GW are covered by the static 10/8 172.16/12 192.168/16 rows.
no_steal_needs_host() {
	local ip="$1"
	is_ipv4 "$ip" || return 1
	case "$ip" in
		127.*) return 1 ;;
	esac
	if is_rfc1918 "$ip"; then
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
	_clear_bypass_fib_rules
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
	_clear_bypass_fib_rules
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

# Dest @bypass_ip must FIB via main even when the socket already has SO_MARK
# 0x2023 (nft OUTPUT unmark runs after connect() lookup).
_clear_bypass_fib_rules() {
	local i=0
	while [ "$i" -lt 64 ]; do
		if ip -4 rule del pref "$BYPASS_RULE_PREF" 2>/dev/null; then
			i=$((i + 1))
			continue
		fi
		break
	done
}

_each_bypass_ip() {
	[ -f "$BYPASS_AUDIT" ] || return 0
	local ip
	while read -r ip; do
		ip="${ip%%/*}"
		ip="${ip%%#*}"
		ip="$(echo "$ip" | tr -d ' \t\r')"
		[ -n "$ip" ] || continue
		is_ipv4 "$ip" || continue
		echo "$ip"
	done < "$BYPASS_AUDIT"
}

apply_bypass_fib_rules() {
	local ip n=0
	_clear_bypass_fib_rules
	for ip in $(_each_bypass_ip); do
		if ip -4 rule add pref "$BYPASS_RULE_PREF" to "$ip" lookup main 2>/dev/null || \
			ip -4 rule add pref "$BYPASS_RULE_PREF" to "$ip/32" lookup main 2>/dev/null || \
			ip -4 rule add pref "$BYPASS_RULE_PREF" to "$ip" table main 2>/dev/null; then
			n=$((n + 1))
		else
			echo "WARN: ip rule pref $BYPASS_RULE_PREF to $ip lookup main failed" >&2
		fi
	done
	[ "$n" -gt 0 ] && echo "bypass fib: $n dest(s) pref $BYPASS_RULE_PREF lookup main"
}

apply_bypass_policy_host_routes() {
	local ip via dev def
	def="$(ip -4 route show default 2>/dev/null | awk '/^default/ { print; exit }')"
	[ -n "$def" ] || return 0
	echo "$def" | grep -qw "dev $TUN_IFACE" && return 0
	via="$(echo "$def" | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
	dev="$(echo "$def" | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
	[ -n "$dev" ] || return 0
	for ip in $(_each_bypass_ip); do
		if [ -n "$via" ]; then
			ip -4 route replace "$ip/32" via "$via" dev "$dev" onlink table "$TABLE" 2>/dev/null || \
				ip -4 route replace "$ip/32" via "$via" dev "$dev" table "$TABLE" 2>/dev/null || true
		else
			ip -4 route replace "$ip/32" dev "$dev" table "$TABLE" 2>/dev/null || true
		fi
	done
}

apply_wan_nat() {
	local proxy_mode masq_match isp ce err
	proxy_mode="$(load_proxy_mode)"
	masq_match="    oifname \"$WAN_IFACE\" masquerade"
	if [ "$proxy_mode" = "bypass" ]; then
		masq_match="    oifname \"$WAN_IFACE\" ip saddr $LAN_CIDR masquerade"
	elif [ "$proxy_mode" = "transparent" ]; then
		isp="$(load_trans_isp)"
		ce="$(load_trans_ce)"
		masq_match=""
		# Hitch SNAT only. DNAT/DNS trampoline are added afterwards so a
		# syntax miss cannot wipe inet nat (set -e).
		if is_hitch_ce "$ce"; then
			# DNS server replies (sport 53) must not hitch-SNAT to CE.
			# Later oif SNAT would overwrite conntrack un-DNAT / trampoline
			# and emit src=CE dst=CE; clients drop that as a martian timeout.
			masq_match="    udp sport 53 return
    tcp sport 53 return"
			if [ -n "$isp" ]; then
				masq_match="$masq_match
    oifname \"$isp\" meta nfproto ipv4 snat ip to $ce"
			fi
			if ip link show br-trans >/dev/null 2>&1; then
				masq_match="$masq_match
    oifname \"br-trans\" meta nfproto ipv4 ip saddr != $ce snat ip to $ce"
			fi
		fi
		[ -n "$masq_match" ] || masq_match="    ip saddr $LAN_CIDR accept"
	fi
	err="$(mktemp)"
	nft delete table inet nat 2>/dev/null || true
	if ! nft -f - <<EOF 2>"$err"
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$masq_match
  }
}
EOF
	then
		echo "WARN: apply_wan_nat: $(tr '\n' ' ' <"$err")" >&2
		nft -f - <<EOF 2>/dev/null || true
table inet nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $LAN_CIDR accept
  }
}
EOF
		rm -f "$err"
		return 1
	fi
	rm -f "$err"
	if [ "$proxy_mode" = "transparent" ]; then
		apply_trans_dns_snat || true
	fi
}

# DNS replies must keep the resolver the client asked (NFT §9.4). Insert at
# head, before sport-53 return + hitch SNAT. The return in apply_wan_nat is
# the stop so hitch SNAT cannot overwrite. Never fail the table.
apply_trans_dns_snat() {
	local cpe proto oif err ce
	cpe="$(load_trans_cpe)"
	ce="$(load_trans_ce)"
	[ -n "$cpe" ] || return 0
	err="$(mktemp)" || return 0
	for proto in udp tcp; do
		for oif in "$cpe" br-trans "$(load_trans_isp)"; do
			ip link show "$oif" >/dev/null 2>&1 || continue
			: >"$err"
			# Skip when original daddr is already CE: that is a new
			# flow (unbound replied from the wrong src), not a DNAT reverse.
			if is_hitch_ce "$ce"; then
				if nft insert rule inet nat postrouting meta nfproto ipv4 oifname "$oif" "$proto" sport 53 ct original ip daddr != "$ce" snat ip to ct original ip daddr 2>"$err"; then
					continue
				fi
			fi
			if nft insert rule inet nat postrouting meta nfproto ipv4 oifname "$oif" "$proto" sport 53 snat ip to ct original ip daddr 2>"$err"; then
				continue
			fi
			if nft insert rule inet nat postrouting meta nfproto ipv4 oifname "$oif" "$proto" sport 53 snat ip to ct original daddr 2>"$err"; then
				continue
			fi
			echo "WARN: transparent DNS trampoline SNAT $proto oif $oif: $(tr '\n' ' ' <"$err")" >&2
		done
	done
	rm -f "$err"
	return 0
}

apply_dns_hijack() {
	local proxy_mode hosts wan_rules set_block wan_local wan_ips hijack lan_rules trans_rules vip exclude exclude_set cpe_if
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
		trans_rules=""
		# Stolen DNS RX: veth gfc-ce, macvlan gfc-rx, bridge, or remaining slave iif.
		for iif in $(load_trans_steal_iifs); do
			[ -n "$iif" ] || continue
			trans_rules="$trans_rules
    iifname \"$iif\" udp dport 53 ip daddr $vip return
    iifname \"$iif\" tcp dport 53 ip daddr $vip return
    iifname \"$iif\" udp dport 53 ip daddr @dns_exclude return
    iifname \"$iif\" tcp dport 53 ip daddr @dns_exclude return"
		done
		if [ "$hijack" = "on" ]; then
			for iif in $(load_trans_steal_iifs); do
				[ -n "$iif" ] || continue
				trans_rules="$trans_rules
    iifname \"$iif\" udp dport 53 dnat ip to $vip
    iifname \"$iif\" tcp dport 53 dnat ip to $vip"
			done
		fi
	fi
	nft delete table inet gfc_dns_hijack 2>/dev/null || true
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

# Stop every netifd interface bound to isp/cpe while they are br-trans slaves.
# Persist the previous autostart value in UCI so leave-trans can restore it
# after a reboot as well as within the current process lifetime.
release_wan_from_netifd() {
	command -v uci >/dev/null 2>&1 || return 0
	local isp cpe section dev marker old changed=0
	isp="$(load_trans_isp)"
	cpe="$(load_trans_cpe)"
	[ -n "$isp" ] || [ -n "$cpe" ] || return 0
	for section in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=interface$/\1/p'); do
		dev="$(uci -q get "network.${section}.device" 2>/dev/null || true)"
		[ "$dev" = "$isp" ] || [ "$dev" = "$cpe" ] || continue
		marker="$(uci -q get "network.${section}.gfc_trans_auto_before" 2>/dev/null || true)"
		if [ -z "$marker" ]; then
			old="$(uci -q get "network.${section}.auto" 2>/dev/null || true)"
			[ -n "$old" ] || old="__unset__"
			# Migrate network.wan.auto=0 written by the pre-marker implementation.
			[ "$section" = "wan" ] && [ "$old" = "0" ] && old="__unset__"
			uci -q set "network.${section}.gfc_trans_auto_before=${old}"
		fi
		ifdown "$section" 2>/dev/null || true
		uci -q set "network.${section}.auto=0"
		changed=1
	done
	[ "$changed" = "0" ] || uci -q commit network
}

restore_wan_uci_auto() {
	command -v uci >/dev/null 2>&1 || return 0
	local section marker changed=0 restart=""
	for section in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=interface$/\1/p'); do
		marker="$(uci -q get "network.${section}.gfc_trans_auto_before" 2>/dev/null || true)"
		[ -n "$marker" ] || continue
		if [ "$marker" = "__unset__" ]; then
			uci -q delete "network.${section}.auto"
			restart="$restart $section"
		else
			uci -q set "network.${section}.auto=${marker}"
			[ "$marker" = "0" ] || restart="$restart $section"
		fi
		uci -q delete "network.${section}.gfc_trans_auto_before"
		changed=1
	done
	if [ "$(uci -q get network.wan.disabled 2>/dev/null || true)" = "1" ]; then
		uci -q delete network.wan.disabled
		changed=1
	fi
	# Must not be `[ x ] && commit` — under set -e that returns 1 when unchanged
	# and aborts start_rules after stop_rules already deleted inet nat/gfc.
	if [ "$changed" = "1" ]; then
		uci -q commit network || true
	fi
	for section in $restart; do
		ifup "$section" 2>/dev/null || true
	done
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
		tc qdisc del dev "$cpe" ingress 2>/dev/null || true
		ip link set "$cpe" nomaster 2>/dev/null || true
		ip link set "$cpe" promisc off 2>/dev/null || true
	fi
	del_trans_dev br-trans
	del_trans_dev gfc-ce
	del_trans_dev gfc-ce-fwd
	del_trans_dev gfc-dns
	del_trans_dev "$PUNT_MACVLAN"
	del_trans_dev "$PUNT_IFB"
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

# dest-MAC rewrite in nft does not clear PACKET_OTHERHOST (set in eth_type_trans
# before netdev). ip_rcv then drops; br-trans rx_otherhost climbs. tc ingress
# runs before nft; skbedit ptype host so stolen DNS can enter inet on br-trans.
# veth fwd already produces HOST — do not install this qdisc on that path.
clear_trans_tc_ingress() {
	local cpe
	cpe="$(load_trans_cpe)"
	[ -n "$cpe" ] || return 0
	tc qdisc del dev "$cpe" ingress 2>/dev/null || true
}

apply_trans_tc_dns_ptype() {
	local cpe
	cpe="$(load_trans_cpe)"
	[ -n "$cpe" ] || return 1
	ip link show "$cpe" >/dev/null 2>&1 || return 1
	modprobe act_skbedit 2>/dev/null || true
	modprobe cls_u32 2>/dev/null || true
	modprobe sch_ingress 2>/dev/null || true
	tc qdisc del dev "$cpe" ingress 2>/dev/null || true
	if ! tc qdisc add dev "$cpe" handle ffff: ingress 2>/dev/null; then
		echo "WARN: tc ingress on $cpe failed; DNS steal may drop OTHERHOST" >&2
		return 1
	fi
	if ! tc filter add dev "$cpe" parent ffff: protocol ip prio 1 u32 \
		match ip protocol 17 0xff match ip dport 53 0xffff \
		action skbedit ptype host 2>/dev/null; then
		echo "WARN: tc skbedit udp/53 on $cpe failed" >&2
		return 1
	fi
	tc filter add dev "$cpe" parent ffff: protocol ip prio 2 u32 \
		match ip protocol 6 0xff match ip dport 53 0xffff \
		action skbedit ptype host 2>/dev/null || true
	echo "transparent: tc $cpe ingress skbedit ptype host for :53"
	return 0
}

# gfc-dns stays dummy (address holder only). gfc-ce cannot: nft `fwd` is
# dev_queue_xmit, and dummy_xmit kfree's the skb (no RX / no inet prerouting).
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
		echo "WARN: kmod-dummy missing; $name is an empty bridge" >&2
	else
		echo "ERROR: cannot create $name (need kmod-dummy)" >&2
		return 1
	fi
	ip link set "$name" up 2>/dev/null || return 1
	ip link set "$name" arp off 2>/dev/null || true
	return 0
}

# macvlan on br-trans when kmod-veth is missing. CPE steal is MAC-punt + accept
# (not nft fwd). macvlan_handle_frame sets pkt_type=HOST and skb->dev=gfc-rx.
# nft fwd to ifb does not set skb->redirected; ifb_xmit then kfree_skb.
# Name must fit IFNAMSIZ (gfc-macvlan-probe was 16 chars and failed).
ensure_ce_macvlan() {
	local name="$PUNT_MACVLAN" vip mac
	[ -n "$name" ] || return 1
	ip link show br-trans >/dev/null 2>&1 || return 1
	modprobe macvlan 2>/dev/null || true
	if ip link show "$name" >/dev/null 2>&1; then
		if ip -d link show "$name" 2>/dev/null | grep -qw macvlan; then
			:
		else
			echo "WARN: $name exists but is not macvlan; recreating" >&2
			del_trans_dev "$name"
		fi
	fi
	if ! ip link show "$name" >/dev/null 2>&1; then
		if ! ip link add name "$name" link br-trans type macvlan mode bridge 2>/dev/null; then
			echo "ERROR: ip link add macvlan $name on br-trans failed" >&2
			return 1
		fi
		echo "transparent: $name type macvlan on br-trans (CPE steal RX; no veth)"
	fi
	ip link set "$name" up 2>/dev/null || return 1
	ip link set "$name" arp off 2>/dev/null || true
	mac="$(hw_mac "$name")"
	if [ -n "$mac" ]; then
		bridge fdb replace "$mac" dev br-trans local 2>/dev/null || \
			bridge fdb add "$mac" dev br-trans local 2>/dev/null || true
	fi
	vip="$(load_dns_vip)"
	if is_ipv4 "$vip"; then
		ip addr replace "$vip/32" dev "$name" noprefixroute 2>/dev/null || true
	fi
	return 0
}

# inet DNAT/classify iifs for stolen frames (veth RX, macvlan RX, bridge, slaves).
load_trans_steal_iifs() {
	local iif seen=""
	for iif in gfc-ce "$PUNT_MACVLAN" br-trans "$PUNT_IFB" "$(load_trans_isp)" "$(load_trans_cpe)"; do
		[ -n "$iif" ] || continue
		ip link show "$iif" >/dev/null 2>&1 || continue
		case " $seen " in
			*" $iif "*) continue ;;
		esac
		seen="$seen $iif"
		echo "$iif"
	done
}

# refresh-trans does not rebuild inet gfc. Append steal iif rows when missing.
ensure_trans_steal_inet() {
	local iif cn=""
	nft list table inet gfc >/dev/null 2>&1 || return 0
	for iif in "$PUNT_MACVLAN" "$PUNT_IFB"; do
		[ -n "$iif" ] || continue
		ip link show "$iif" >/dev/null 2>&1 || continue
		if nft list chain inet gfc prerouting_mangle_ct 2>/dev/null | grep -q "iifname \"$iif\""; then
			continue
		fi
		cn=""
		if [ "$(load_routing_mode)" != "global" ]; then
			cn="add rule inet gfc prerouting_mangle_route iifname \"$iif\" ip daddr @TO_CN return"
		fi
		nft -f - <<EOF
add rule inet gfc prerouting_mangle_ct iifname "$iif" ct mark set $MARK accept
add rule inet gfc prerouting_mangle_route iifname "$iif" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
add rule inet gfc prerouting_mangle_route iifname "$iif" ip daddr $LAN_CIDR return
add rule inet gfc prerouting_mangle_route iifname "$iif" udp dport { 53, 67, 68, 123 } return
add rule inet gfc prerouting_mangle_route iifname "$iif" ip daddr @bypass_ip return
add rule inet gfc prerouting_mangle_route iifname "$iif" ip daddr @ext_const ct mark $MARK meta mark set ct mark return
$cn
add rule inet gfc prerouting_mangle_route iifname "$iif" ct mark $MARK meta mark set ct mark
EOF
	done
}

# Load veth.ko even if modules.dep is stale (common after OEM incremental).
load_veth_ko() {
	local kver ko
	if lsmod 2>/dev/null | grep -q '^veth'; then
		return 0
	fi
	modprobe veth 2>/dev/null || true
	if lsmod 2>/dev/null | grep -q '^veth'; then
		return 0
	fi
	kver="$(uname -r 2>/dev/null || true)"
	[ -n "$kver" ] || return 1
	ko="$(find "/lib/modules/$kver" -name 'veth.ko*' 2>/dev/null | head -1 || true)"
	if [ -n "$ko" ]; then
		insmod "$ko" 2>/dev/null || true
	fi
	lsmod 2>/dev/null | grep -q '^veth'
}

try_veth_add() {
	local a="$1" b="$2" err
	err="$(ip link add name "$a" type veth peer name "$b" 2>&1)" && return 0
	err="$(ip link add "$a" type veth peer name "$b" 2>&1)" && return 0
	err="$(ip link add name "$a" type veth peer "$b" 2>&1)" && return 0
	echo "ERROR: ip link add veth $a/$b: $err" >&2
	return 1
}

# veth: nft fwd to gfc-ce-fwd appears as RX on gfc-ce (inet iifname gfc-ce).
# Do not delete gfc-ce until a veth create has succeeded — a failed add used to
# leave no bind address and skip the whole steal table.
ensure_ce_veth() {
	if [ -f /tmp/gfc-veth-missing ]; then
		return 1
	fi
	if ip link show gfc-ce >/dev/null 2>&1 && ip link show gfc-ce-fwd >/dev/null 2>&1; then
		if ip -d link show gfc-ce 2>/dev/null | grep -qw veth; then
			ip link set gfc-ce up 2>/dev/null || true
			ip link set gfc-ce-fwd up 2>/dev/null || true
			ip link set gfc-ce arp off 2>/dev/null || true
			ip link set gfc-ce-fwd arp off 2>/dev/null || true
			return 0
		fi
	fi
	if ! load_veth_ko; then
		touch /tmp/gfc-veth-missing 2>/dev/null || true
		echo "ERROR: veth.ko not loaded (need kmod-veth in image)" >&2
		return 1
	fi
	# Probe names must be ≤15 bytes (IFNAMSIZ including NUL).
	# gfc-ce-fwd-probe is 16 and iproute2 rejects it, which used to
	# sticky-fail this boot even though gfc-ce / gfc-ce-fwd are valid.
	del_trans_dev gfc-vp0
	del_trans_dev gfc-vp1
	del_trans_dev gfc-ce-probe
	del_trans_dev gfc-ce-fwd-probe
	if ! try_veth_add gfc-vp0 gfc-vp1; then
		touch /tmp/gfc-veth-missing 2>/dev/null || true
		return 1
	fi
	del_trans_dev gfc-vp0
	del_trans_dev gfc-vp1
	del_trans_dev gfc-ce
	del_trans_dev gfc-ce-fwd
	if ! try_veth_add gfc-ce gfc-ce-fwd; then
		return 1
	fi
	ip link set gfc-ce up 2>/dev/null || return 1
	ip link set gfc-ce-fwd up 2>/dev/null || return 1
	ip link set gfc-ce arp off 2>/dev/null || true
	ip link set gfc-ce-fwd arp off 2>/dev/null || true
	echo "transparent: gfc-ce/gfc-ce-fwd type veth"
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
	for dev in "$isp" "$cpe" br-trans gfc-ce gfc-ce-fwd gfc-dns "$PUNT_MACVLAN" "$PUNT_IFB"; do
		[ -n "$dev" ] || continue
		sysctl -w "net.ipv4.conf.${dev}.rp_filter=2" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_ignore=2" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.arp_announce=2" >/dev/null 2>&1 || true
		sysctl -w "net.ipv4.conf.${dev}.accept_local=1" >/dev/null 2>&1 || true
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
	modprobe veth 2>/dev/null || true
	modprobe macvlan 2>/dev/null || true
	if ensure_ce_veth; then
		del_trans_dev "$PUNT_IFB"
		del_trans_dev "$PUNT_MACVLAN"
	else
		echo "WARN: gfc-ce veth failed; dummy + MAC-punt on br-trans" >&2
		ensure_dummy gfc-ce || echo "WARN: gfc-ce missing; hitch bind IP cannot be mounted" >&2
		del_trans_dev "$PUNT_IFB"
	fi
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
	ip link set br-trans promisc on 2>/dev/null || true
	ip addr flush dev br-trans 2>/dev/null || true
	del_trans_dev "$PUNT_MACVLAN"
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
		# Not in table local: tun replies to the real CPE must not be swallowed.
		# Hitch returns (iif gfc-ce dest=$ce) need inet nat DNAT to 172.31.253.1.
		ip route del table local "$ce/32" 2>/dev/null || true
		# Do not route via the enslaved cpe port — L3 must use br-trans.
		# src must be DNS VIP so unbound replies match DNAT reverse
		# (dest VIP). Otherwise kernel picks br-lan and postrouting
		# trampoline SNATs src to CE (original daddr of the new flow).
		if [ -n "$l3" ]; then
			if is_ipv4 "$vip"; then
				ip addr replace "$vip/32" dev "$l3" noprefixroute 2>/dev/null || true
				ip route replace "$ce/32" dev "$l3" src "$vip" 2>/dev/null || \
					ip route replace "$ce/32" dev "$l3" 2>/dev/null || true
			else
				ip route replace "$ce/32" dev "$l3" 2>/dev/null || true
			fi
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
			ip route replace default via "$gw" dev "$l3" onlink src 172.31.253.1 2>/dev/null || \
				ip route replace default via "$gw" dev "$l3" onlink 2>/dev/null || \
				ip route replace default via "$gw" dev "$l3" 2>/dev/null || true
		fi
	fi
}

apply_trans_netdev() {
	local isp cpe vip hijack tun_up exclude no_steal ce gw
	local isp_mac cpe_hw learned_cpe_mac pe_mac
	local dns_vip_rules dns_steal tcp_steal mac_isp mac_cpe mac_trans hitch_upd hitch_local exclude_set
	local tmp err punt_fwd punt_mac punt_end punt_mode hitch_end trans_mac
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
	punt_mode=""
	punt_end=""
	punt_fwd=""
	punt_mac=""
	hitch_end=""
	if ip link show gfc-ce >/dev/null 2>&1 && ip link show gfc-ce-fwd >/dev/null 2>&1 && ip -d link show gfc-ce 2>/dev/null | grep -qw veth; then
		punt_mode="veth"
		punt_fwd="gfc-ce-fwd"
		punt_mac="$(hw_mac gfc-ce)"
		punt_end="ether daddr set $punt_mac fwd to \"$punt_fwd\""
		hitch_end="$punt_end"
	elif [ -n "$(hw_mac br-trans)" ]; then
		# No veth: MAC-punt to the bridge's own MAC (already local in FDB).
		# nft fwd to ifb drops (no skb->redirected). macvlan dest is not local.
		punt_mode="mac"
		punt_fwd="br-trans"
		punt_mac="$(hw_mac br-trans)"
		punt_end="ether daddr set $punt_mac accept"
		hitch_end="$punt_end"
		ip link set br-trans promisc on 2>/dev/null || true
		echo "transparent: steal MAC-punt $punt_mac on br-trans (no veth; iif br-trans)" >&2
	else
		punt_mode="mac"
		ensure_dummy gfc-ce || true
		if ! ip link show br-trans >/dev/null 2>&1; then
			echo "WARN: br-trans missing; skip netdev gfc_trans (L2 fail-open)" >&2
			return 1
		fi
		punt_fwd="br-trans"
		punt_mac="$(hw_mac br-trans)"
		punt_end="ether daddr set $punt_mac accept"
		hitch_end="$punt_end"
		echo "transparent: punt last-resort ether daddr set $punt_mac accept (no veth/macvlan; OTHERHOST drops DNS)" >&2
	fi
	[ -n "$hitch_end" ] || hitch_end="$punt_end"
	if [ -z "$punt_mac" ] || [ -z "$punt_end" ]; then
		echo "WARN: punt dest MAC empty (mode=$punt_mode); skip netdev gfc_trans (L2 fail-open)" >&2
		return 1
	fi
	nft delete table netdev gfc_trans 2>/dev/null || true
	tun_up=0
	ip link show "$TUN_IFACE" >/dev/null 2>&1 && tun_up=1
	no_steal="10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16"
	ce="$(load_trans_ce)"
	gw="$(load_trans_gw)"
	if is_hitch_ce "$ce" && no_steal_needs_host "$ce"; then
		no_steal="$no_steal, $ce"
	fi
	if is_onlink_gw "$ce" "$gw" && no_steal_needs_host "$gw"; then
		no_steal="$no_steal, $gw"
	fi
	dns_vip_rules="
    udp dport 53 ip daddr $vip $punt_end
    tcp dport 53 ip daddr $vip $punt_end"
	dns_steal=""
	if [ "$hijack" = "on" ] && [ "$tun_up" -eq 1 ]; then
		if [ -n "$exclude" ]; then
			dns_steal="
    udp dport 53 ip daddr @dns_exclude accept
    tcp dport 53 ip daddr @dns_exclude accept"
		fi
		dns_steal="$dns_steal
    udp dport 53 $punt_end
    tcp dport 53 $punt_end"
	fi
	tcp_steal=""
	if [ "$tun_up" -eq 1 ]; then
		tcp_steal="
    ip daddr @no_steal_dst accept
    meta l4proto tcp $punt_end"
	fi
	hitch_src_macs=""
	for _cand in "$isp_mac" "$(hw_mac br-trans)" "$(hw_mac gfc-ce)"; do
		[ -n "$_cand" ] || continue
		_dup=0
		for _have in $hitch_src_macs; do
			if [ "$_have" = "$_cand" ]; then
				_dup=1
				break
			fi
		done
		[ "$_dup" = 1 ] || hitch_src_macs="$hitch_src_macs $_cand"
	done
	mac_isp=""
	mac_trans=""
	if [ -n "$learned_cpe_mac" ] && [ -n "$pe_mac" ]; then
		mac_isp="
    ether saddr != $learned_cpe_mac ether saddr set $learned_cpe_mac ether daddr set $pe_mac"
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
	tmp="$(mktemp)"
	err="$(mktemp)"
	# `{ tcp . ip daddr ...}` is a syntax error on this SKU: nft parses `tcp` as
	# a header expression (sport/dport), not inet_proto. First concat field must
	# be `meta l4proto`. fwd target is gfc-ce-fwd (veth TX); dest MAC must be
	# gfc-ce or ip_rcv drops PACKET_OTHERHOST. Keep dest=CE so inet DNAT on
	# iif gfc-ce updates L4 checksums. ip daddr set is a last-resort dialect.
	hitch_bind="172.31.253.1"
	hitch_in_l4="
    meta l4proto tcp meta l4proto . ip saddr . tcp sport . ip daddr . tcp dport @hitch_reply $hitch_end
    meta l4proto udp meta l4proto . ip saddr . udp sport . ip daddr . udp dport @hitch_reply $hitch_end"
	hitch_in_l4_set="
    meta l4proto tcp meta l4proto . ip saddr . tcp sport . ip daddr . tcp dport @hitch_reply ip daddr set $hitch_bind $hitch_end
    meta l4proto udp meta l4proto . ip saddr . udp sport . ip daddr . udp dport @hitch_reply ip daddr set $hitch_bind $hitch_end"
	hitch_in_th="
    meta l4proto { tcp, udp } meta l4proto . ip saddr . th sport . ip daddr . th dport @hitch_reply $hitch_end"
	hitch_in_th_set="
    meta l4proto { tcp, udp } meta l4proto . ip saddr . th sport . ip daddr . th dport @hitch_reply ip daddr set $hitch_bind $hitch_end"
	hitch_upd_l4=""
	hitch_upd_th=""
	hitch_local_l4=""
	hitch_local_th=""
	mac_trans=""
	if is_hitch_ce "$ce" && [ -n "$learned_cpe_mac" ] && [ -n "$pe_mac" ]; then
		# Internet hitch: not dest=CE. DNS/trampoline replies dest=CE must go CPE, not PE.
		hitch_local_l4="
    ip daddr != $ce ip protocol tcp update @hitch_reply { meta l4proto . ip daddr . tcp dport . ip saddr . tcp sport timeout 2m }
    ip daddr != $ce ip protocol udp update @hitch_reply { meta l4proto . ip daddr . udp dport . ip saddr . udp sport timeout 2m }"
		hitch_local_th="
    ip daddr != $ce meta l4proto { tcp, udp } update @hitch_reply { meta l4proto . ip daddr . th dport . ip saddr . th sport timeout 2m }"
		mac_trans="
    ip daddr != $ce ether saddr set $learned_cpe_mac ether daddr set $pe_mac
    ip daddr $ce ether saddr set $pe_mac ether daddr set $learned_cpe_mac"
	else
		hitch_local_l4="
    ip protocol tcp update @hitch_reply { meta l4proto . ip daddr . tcp dport . ip saddr . tcp sport timeout 2m }
    ip protocol udp update @hitch_reply { meta l4proto . ip daddr . udp dport . ip saddr . udp sport timeout 2m }"
		hitch_local_th="
    meta l4proto { tcp, udp } update @hitch_reply { meta l4proto . ip daddr . th dport . ip saddr . th sport timeout 2m }"
		if [ -n "$learned_cpe_mac" ] && [ -n "$pe_mac" ]; then
			mac_trans="
    ether saddr set $learned_cpe_mac ether daddr set $pe_mac"
		fi
	fi
	if [ -n "$learned_cpe_mac" ]; then
		hitch_upd_l4="
    ether saddr != $learned_cpe_mac ip protocol tcp update @hitch_reply { meta l4proto . ip daddr . tcp dport . ip saddr . tcp sport timeout 2m }
    ether saddr != $learned_cpe_mac ip protocol udp update @hitch_reply { meta l4proto . ip daddr . udp dport . ip saddr . udp sport timeout 2m }"
		hitch_upd_th="
    ether saddr != $learned_cpe_mac meta l4proto { tcp, udp } update @hitch_reply { meta l4proto . ip daddr . th dport . ip saddr . th sport timeout 2m }"
	else
		for m in $hitch_src_macs; do
			hitch_upd_l4="$hitch_upd_l4
    ether saddr $m ip protocol tcp update @hitch_reply { meta l4proto . ip daddr . tcp dport . ip saddr . tcp sport timeout 2m }
    ether saddr $m ip protocol udp update @hitch_reply { meta l4proto . ip daddr . udp dport . ip saddr . udp sport timeout 2m }"
			hitch_upd_th="$hitch_upd_th
    ether saddr $m meta l4proto { tcp, udp } update @hitch_reply { meta l4proto . ip daddr . th dport . ip saddr . th sport timeout 2m }"
		done
	fi
	loaded=0
	last_err=""
	hitch_used=""
	for dialect in th l4 th_set l4_set; do
		case "$dialect" in
			th) hitch_in="$hitch_in_th"; hitch_upd="$hitch_upd_th"; hitch_local="$hitch_local_th" ;;
			l4) hitch_in="$hitch_in_l4"; hitch_upd="$hitch_upd_l4"; hitch_local="$hitch_local_l4" ;;
			th_set) hitch_in="$hitch_in_th_set"; hitch_upd="$hitch_upd_th"; hitch_local="$hitch_local_th" ;;
			*) hitch_in="$hitch_in_l4_set"; hitch_upd="$hitch_upd_l4"; hitch_local="$hitch_local_l4" ;;
		esac
		cat > "$tmp" <<EOF
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
$hitch_in
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
  chain eg_trans {
    type filter hook egress device "br-trans" priority 0; policy accept;
$hitch_local
$mac_trans
  }
  chain eg_cpe {
    type filter hook egress device "$cpe" priority 0; policy accept;
$mac_cpe
  }
}
EOF
		nft delete table netdev gfc_trans 2>/dev/null || true
		if nft -f "$tmp" 2>"$err"; then
			loaded=1
			hitch_used="$dialect"
			break
		fi
		last_err="$(tr '\n' ' ' <"$err")"
	done
	rm -f "$tmp" "$err"
	if [ "$loaded" -ne 1 ]; then
		echo "WARN: nft netdev gfc_trans failed: $last_err" >&2
		return 1
	fi
	if ! nft list table netdev gfc_trans >/dev/null 2>&1; then
		echo "WARN: netdev gfc_trans missing after load" >&2
		return 1
	fi
	fill_netdev_no_steal
	if [ "$punt_mode" = "veth" ]; then
		clear_trans_tc_ingress
	else
		apply_trans_tc_dns_ptype || echo "WARN: tc DNS ptype host failed (OTHERHOST drops steal)" >&2
	fi
	echo "transparent netdev gfc_trans: isp=$isp cpe=$cpe hijack=$hijack tun=$tun_up vip=$vip hitch=$hitch_used punt=$punt_mode fwd=$punt_fwd eg_trans=1"
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
	if ensure_ce_veth; then
		del_trans_dev "$PUNT_IFB"
		del_trans_dev "$PUNT_MACVLAN"
	else
		echo "WARN: gfc-ce veth failed; dummy + MAC-punt on br-trans" >&2
		ensure_dummy gfc-ce || echo "WARN: gfc-ce missing" >&2
		del_trans_dev "$PUNT_IFB"
		del_trans_dev "$PUNT_MACVLAN"
		ip link set br-trans promisc on 2>/dev/null || true
	fi
	ensure_dummy gfc-dns || echo "WARN: gfc-dns missing" >&2
	apply_trans_sysctl
	apply_trans_addrs
	# Learning often completes after start_rules; hitch SNAT must follow CE.
	apply_wan_nat || echo "WARN: hitch NAT refresh failed" >&2
	apply_dns_hijack || echo "WARN: DNS hijack refresh failed" >&2
	ensure_trans_steal_inet || true
	apply_trans_netdev || echo "WARN: netdev gfc_trans refresh failed (L2 fail-open)" >&2
	write_bypass_unbound_acl
	if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
		# start_rules may have exited on flock/TUN wait before this route existed.
		ip -4 route replace default dev "$TUN_IFACE" table "$TABLE" || \
			echo "WARN: policy table $TABLE default via $TUN_IFACE failed" >&2
		apply_bypass_policy_host_routes
		apply_bypass_fib_rules
	fi
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
	local ext_const routing_mode proxy_mode hosts ce isp
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
		cn_output_rule="    ip daddr @TO_CN meta mark set 0x00000000 ct mark set 0x00000000 return"
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
		output_customer_rule="    ip daddr @customer_hosts meta mark set 0x00000000 ct mark set 0x00000000 return"
	fi
	if [ "$proxy_mode" = "transparent" ]; then
		isp="$(load_trans_isp)"
		ct_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		route_head="    iifname \"$TUN_IFACE\" return
    fib daddr type { local, broadcast, multicast } return"
		ct_wan=""
		route_wan=""
		cn_wan_rule=""
		for iif in $(load_trans_steal_iifs); do
			[ -n "$iif" ] || continue
			ct_wan="$ct_wan
    iifname \"$iif\" ct mark set $MARK accept"
			if [ "$routing_mode" != "global" ]; then
				cn_wan_rule="$cn_wan_rule
    iifname \"$iif\" ip daddr @TO_CN return"
			fi
			route_wan="$route_wan
    iifname \"$iif\" ip daddr { 10.0.0.0/8, 127.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    iifname \"$iif\" ip daddr $LAN_CIDR return
    iifname \"$iif\" udp dport { 53, 67, 68, 123 } return
    iifname \"$iif\" ip daddr @bypass_ip return
    iifname \"$iif\" ip daddr @ext_const ct mark $MARK meta mark set ct mark return"
		done
		route_wan="$route_wan
${cn_wan_rule}"
		for iif in $(load_trans_steal_iifs); do
			[ -n "$iif" ] || continue
			route_wan="$route_wan
    iifname \"$iif\" ct mark $MARK meta mark set ct mark"
		done
		ce="$(load_trans_ce)"
		if is_hitch_ce "$ce"; then
			forward_customer="    ct state new ip saddr $ce ct mark set meta mark"
			output_customer_rule="    ip daddr $ce meta mark set 0x00000000 ct mark set 0x00000000 return"
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
    tcp dport $SSH_PORT meta mark set 0x00000000 ct mark set 0x00000000 return
    ip daddr @TO_RFC1918 meta mark set 0x00000000 ct mark set 0x00000000 return
    ip daddr 127.0.0.0/8 meta mark set 0x00000000 ct mark set 0x00000000 return
${output_customer_rule}
${cn_output_rule}
    ip daddr @bypass_ip counter meta mark set 0x00000000 ct mark set 0x00000000 return
    # --- GFC_USER_OVERLAY_OUTPUT_BEGIN (after bypass_ip / before catch-all mark) ---
    jump output_user_overlay
    # --- GFC_USER_OVERLAY_OUTPUT_END ---
    meta mark != 0x00000000 return
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
	apply_bypass_policy_host_routes
	apply_bypass_fib_rules
	ip -4 route flush cache 2>/dev/null || true
	if [ -x "$GFC_ROOT/deploy/apply-tc-htb.sh" ]; then
		sh "$GFC_ROOT/deploy/apply-tc-htb.sh" apply 2>/dev/null || true
	fi
	echo "gfc routing: scheme=$ROUTING_SCHEME proxy=$(load_proxy_mode) mode=$(load_routing_mode) lan=$LAN_IFACE wan=$WAN_IFACE cidr=$LAN_CIDR mark=$MARK table=$TABLE redirect=$REDIRECT_PORT ssh=$SSH_PORT priority=$NFT_PRIORITY output=$OUTPUT_POLICY mosdns_uid=$MOSDNS_UID singbox_uid=$SINGBOX_UID cn=$CN_LIST bypass=$BYPASS_AUDIT"
}

acquire_action_lock

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
		ip -4 rule list | grep "pref $BYPASS_RULE_PREF" || ip -4 rule list | awk -v p="$BYPASS_RULE_PREF" '$1 == p":"' || true
		ip -4 route show table "$TABLE" 2>/dev/null || true
		if [ "$(load_proxy_mode)" = "transparent" ]; then
			echo "trans_ports isp=$(load_trans_isp) cpe=$(load_trans_cpe)"
			echo "trans_learned ce=$(load_trans_ce) gw=$(load_trans_gw) cpe_mac=$(load_trans_cpe_mac) pe_mac=$(load_trans_pe_mac)"
			echo "gfc-ce=$(ip link show gfc-ce >/dev/null 2>&1 && echo yes || echo no) gfc-ce-fwd=$(ip link show gfc-ce-fwd >/dev/null 2>&1 && echo yes || echo no) gfc-dns=$(ip link show gfc-dns >/dev/null 2>&1 && echo yes || echo no) $PUNT_MACVLAN=$(ip link show "$PUNT_MACVLAN" >/dev/null 2>&1 && echo yes || echo no) $PUNT_IFB=$(ip link show "$PUNT_IFB" >/dev/null 2>&1 && echo yes || echo no)"
			echo "gfc_trans=$(nft list table netdev gfc_trans >/dev/null 2>&1 && echo yes || echo no)"
			echo "default=$(ip -4 route show default 2>/dev/null | head -1)"
			echo "modules=$(lsmod 2>/dev/null | awk '/dummy|veth|macvlan|ifb|nft_fwd|nft_netdev/ { printf \"%s \", $1 }')"
			echo "veth_ko=$(find /lib/modules/$(uname -r) -name 'veth.ko*' 2>/dev/null | head -1)"
		fi
		;;
	*) echo "usage: $0 {start|direct|stop|restart|status|refresh-trans|leave-trans}" >&2; exit 2 ;;
esac
