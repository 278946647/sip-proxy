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

echo "==> verify dataplane (LAN gateway $LAN_ADDR)"

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

if nft list table inet gfc_dns_hijack >/dev/null 2>&1; then
	ok "nft gfc_dns_hijack"
else
	fail "nft gfc_dns_hijack missing (run /etc/init.d/gfc-routing start)"
fi

if nft list table inet nat postrouting 2>/dev/null | grep -q masquerade; then
	ok "WAN masquerade"
else
	fail "WAN masquerade missing (gfc-routing not applied)"
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
