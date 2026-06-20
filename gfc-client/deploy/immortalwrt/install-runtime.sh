#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_WEB_PORT="${GFC_CLIENT_WEB_PORT:-8080}"
GFC_MOSDNS_PORT="${GFC_MOSDNS_PORT:-1053}"
INIT_SRC="${GFC_ROOT}/deploy/immortalwrt/package/files/etc/init.d"

mkdir -p "$GFC_ROOT" "$GFC_ETC" "$GFC_LIB/state" "$GFC_LIB/rules" "$GFC_LIB/dns-lists" "$GFC_LOG_DIR"

if [ ! -d "$INIT_SRC" ]; then
	echo "missing init scripts: $INIT_SRC" >&2
	exit 1
fi

for bin in gfc-api gfc-agent gfc-bootstrap; do
	if [ ! -x "/usr/bin/$bin" ]; then
		echo "missing executable /usr/bin/$bin" >&2
		exit 1
	fi
done

cat >"$GFC_ETC/gfc.env" <<EOF
GFC_PLATFORM=immortalwrt
GFC_ROOT=$GFC_ROOT
GFC_ETC=$GFC_ETC
GFC_LIB=$GFC_LIB
GFC_LOG_DIR=$GFC_LOG_DIR
GFC_WEB_MODE=admin
GFC_CLIENT_WEB_PORT=$GFC_WEB_PORT
GFC_CLIENT_FLASH_PORT=18080
GFC_PROXY_MODE=${GFC_PROXY_MODE:-gateway}
GFC_ROUTING_SCHEME=${GFC_ROUTING_SCHEME:-kernel-split}
GFC_POLICY_MARK=${GFC_POLICY_MARK:-0x2023}
GFC_POLICY_TABLE=${GFC_POLICY_TABLE:-2022}
EOF
chmod 600 "$GFC_ETC/gfc.env"

for svc in gfc-api gfc-agent gfc-mosdns gfc-sing-box gfc-routing; do
	cp "$INIT_SRC/$svc" "/etc/init.d/$svc"
	chmod +x "/etc/init.d/$svc"
done

chmod +x "$GFC_ROOT"/deploy/immortalwrt/*.sh 2>/dev/null || true

# Disable stock mosdns if present; GFC owns its own config path and service.
/etc/init.d/mosdns stop 2>/dev/null || true
/etc/init.d/mosdns disable 2>/dev/null || true

if [ -x /usr/bin/gfc-bootstrap ]; then
	GFC_PLATFORM=immortalwrt \
	GFC_ROOT="$GFC_ROOT" \
	GFC_ETC="$GFC_ETC" \
	GFC_LIB="$GFC_LIB" \
	GFC_LOG_DIR="$GFC_LOG_DIR" \
	gfc-bootstrap || true
fi

if command -v uci >/dev/null 2>&1; then
	cp /etc/config/dhcp "/etc/config/dhcp.bak.gfc.$(date +%s)" 2>/dev/null || true
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci -q delete dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$GFC_MOSDNS_PORT"
	uci set dhcp.@dnsmasq[0].cachesize='0'
	uci commit dhcp
fi

/etc/init.d/gfc-api enable
/etc/init.d/gfc-agent enable
/etc/init.d/gfc-mosdns enable
/etc/init.d/gfc-sing-box enable
/etc/init.d/gfc-routing enable

service_restart() {
	local svc="$1"
	"/etc/init.d/$svc" stop 2>/dev/null || true
	sleep 1
	"/etc/init.d/$svc" start
}

service_restart gfc-api
service_restart gfc-mosdns || true
/etc/init.d/dnsmasq restart || true
service_restart gfc-agent

echo "GFC runtime installed. API: http://127.0.0.1:${GFC_WEB_PORT}/api/v1/status"
