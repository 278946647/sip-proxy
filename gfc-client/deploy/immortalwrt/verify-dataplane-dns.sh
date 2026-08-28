#!/bin/sh
# Post-install / post-upgrade LAN dataplane smoke test (DNS + NAT + core services).
set -eu

FAIL=0
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "OK: $*"; }

ENV_FILE="${GFC_ENV_FILE:-/etc/gfc-client/gfc.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

LAN_ADDR="${GFC_LAN_ADDRESS:-$(uci -q get network.lan.ipaddr 2>/dev/null || true)}"
LAN_ADDR="$(echo "$LAN_ADDR" | tr ' \t' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)"
[ -n "$LAN_ADDR" ] || LAN_ADDR="192.168.1.1"

load_proxy_mode() {
	env_mode="$(echo "${GFC_PROXY_MODE:-}" | tr 'A-Z' 'a-z')"
	file_mode=""
	f="/etc/gfc-client/proxy-mode.json"
	if [ -f "$f" ]; then
		if command -v jsonfilter >/dev/null 2>&1; then
			file_mode="$(jsonfilter -i "$f" -e '@.mode' 2>/dev/null || true)"
		else
			file_mode="$(awk -F'"' '/"mode"[[:space:]]*:/ { print tolower($4); exit }' "$f" 2>/dev/null || true)"
		fi
		file_mode="$(echo "$file_mode" | tr 'A-Z' 'a-z')"
	fi
	if [ "$env_mode" = "bypass" ]; then
		echo "bypass"
		return 0
	fi
	case "$file_mode" in
		bypass) echo "bypass"; return 0 ;;
	esac
	echo "gateway"
}

PROXY_MODE="$(load_proxy_mode)"

echo "==> verify dataplane (LAN gateway $LAN_ADDR mode=$PROXY_MODE)"

for f in \
	/etc/unbound/unbound.conf \
	/etc/unbound/conf.d/cn.unbound.conf \
	/etc/unbound/conf.d/gfc-domestic-forward.conf \
	/etc/unbound/local.d/gfc-block.conf \
	/etc/unbound/local.d/gfc-static.conf
do
	if [ ! -f "$f" ]; then
		fail "missing $f (run gfc-bootstrap)"
	fi
done

if command -v unbound-checkconf >/dev/null 2>&1; then
	if unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1; then
		ok "unbound-checkconf"
	else
		fail "unbound-checkconf /etc/unbound/unbound.conf"
		unbound-checkconf /etc/unbound/unbound.conf 2>&1 | head -10 >&2 || true
	fi
fi

if pidof unbound >/dev/null 2>&1; then
	ok "unbound running"
else
	fail "unbound not running (/etc/init.d/gfc-unbound start)"
fi

if netstat -uln 2>/dev/null | grep -q ':53 '; then
	ok "UDP :53 listening"
else
	fail "nothing listening on UDP :53"
fi

if command -v drill >/dev/null 2>&1; then
	if drill @"$LAN_ADDR" baidu.com +short +time=3 +tries=1 2>/dev/null | grep -qE '^[0-9]'; then
		ok "drill @$LAN_ADDR baidu.com"
	else
		fail "drill @$LAN_ADDR baidu.com (LAN DNS broken)"
	fi
fi

DNS_OPT="$(uci -q get dhcp.lan.dhcp_option 2>/dev/null || true)"
case " $DNS_OPT " in
*" 6,$LAN_ADDR "*|*"6,$LAN_ADDR"*) ok "dhcp option 6=$LAN_ADDR" ;;
*) fail "dhcp.lan.dhcp_option missing 6,$LAN_ADDR (run configure-dnsmasq-dhcp.sh)" ;;
esac

PORT="$(uci -q get dhcp.@dnsmasq[0].port 2>/dev/null || true)"
[ "$PORT" = "0" ] && ok "dnsmasq port=0" || fail "dnsmasq port=$PORT (expected 0)"

REDIR="$(uci -q get dhcp.@dnsmasq[0].dns_redirect 2>/dev/null || true)"
[ "$REDIR" = "0" ] && ok "dnsmasq dns_redirect=0" || fail "dnsmasq dns_redirect=$REDIR (expected 0; 1 + port=0 → redirect to :0)"

if nft list table inet dnsmasq >/dev/null 2>&1; then
	hijack_dnsmasq="$(nft list table inet dnsmasq 2>/dev/null || true)"
	if echo "$hijack_dnsmasq" | grep -qE 'redirect to :0|DNSMASQ HIJACK'; then
		fail "stock inet dnsmasq DNS hijack present (redirect to :0 blackholes UDP/53)"
	else
		fail "table inet dnsmasq exists (run gfc-routing start / configure-dnsmasq-dhcp.sh)"
	fi
else
	ok "no stock inet dnsmasq hijack"
fi

if nft list table inet gfc_dns_hijack >/dev/null 2>&1; then
	ok "nft gfc_dns_hijack"
else
	fail "nft gfc_dns_hijack missing (run /etc/init.d/gfc-routing start)"
fi

NAT_CHAIN="$(nft list chain inet nat postrouting 2>/dev/null || nft list table inet nat 2>/dev/null || true)"
if echo "$NAT_CHAIN" | grep -q masquerade; then
	if [ "$PROXY_MODE" = "bypass" ]; then
		if echo "$NAT_CHAIN" | grep -q 'ip saddr'; then
			ok "WAN masquerade (bypass LAN-only SNAT)"
		else
			fail "bypass NAT must be oif WAN ip saddr <lan> masquerade (not bare WAN masquerade)"
		fi
	else
		ok "WAN masquerade"
	fi
else
	fail "WAN masquerade missing (gfc-routing not applied; use: nft list chain inet nat postrouting)"
fi

if [ "$PROXY_MODE" = "bypass" ]; then
	if nft list set inet gfc customer_hosts >/dev/null 2>&1; then
		ok "nft customer_hosts"
	else
		fail "bypass missing set inet gfc customer_hosts"
	fi
	if nft list chain inet gfc output_mangle_route 2>/dev/null | grep -q 'daddr @customer_hosts'; then
		ok "output_mangle_route customer_hosts return"
	else
		fail "bypass output_mangle_route missing ip daddr @customer_hosts return"
	fi
	if ip -4 rule list 2>/dev/null | grep -q '0x2023'; then
		ok "policy rule fwmark 0x2023"
	else
		fail "bypass missing fwmark 0x2023 policy rule"
	fi
	hijack="$(nft list table inet gfc_dns_hijack 2>/dev/null || true)"
	if echo "$hijack" | grep -q 'type local return'; then
		ok "bypass DNS hijack local-dest skip"
	else
		fail "bypass DNS hijack missing local dest return (WAN IP as DNS would redirect)"
	fi
	if [ -f /etc/unbound/conf.d/gfc-bypass-acl.conf ] && grep -q 'access-control:' /etc/unbound/conf.d/gfc-bypass-acl.conf; then
		if grep -q '0.0.0.0/0' /etc/unbound/conf.d/gfc-bypass-acl.conf; then
			fail "unbound bypass ACL must not allow 0.0.0.0/0"
		else
			ok "unbound gfc-bypass-acl.conf"
		fi
	else
		fail "bypass missing unbound customer_hosts ACL (/etc/unbound/conf.d/gfc-bypass-acl.conf)"
	fi
fi

if [ -x /etc/init.d/firewall ]; then
	if /etc/init.d/firewall enabled >/dev/null 2>&1; then
		fail "stock fw4 enabled — conflicts with GFC nft (run disable-immortalwrt-fw4.sh)"
	else
		ok "fw4 disabled"
	fi
fi

if [ -f /etc/gfc-client/sing-box.json ]; then
	ok "sing-box.json present"
else
	warn "sing-box.json missing (device not bootstrapped / not activated)"
fi

if [ "$FAIL" -ne 0 ]; then
	echo "==> dataplane verify FAILED" >&2
	exit 1
fi
echo "==> dataplane verify passed"
exit 0
