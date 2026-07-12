#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_WEB_PORT="${GFC_CLIENT_WEB_PORT:-8080}"
GFC_MOSDNS_PORT="${GFC_MOSDNS_PORT:-1053}"
GFC_MOSDNS_USER="${GFC_MOSDNS_USER:-mosdns}"
GFC_MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
GFC_SINGBOX_USER="${GFC_SINGBOX_USER:-singbox}"
GFC_SINGBOX_UID="${GFC_SINGBOX_UID:-65354}"
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

ensure_group() {
	local name="$1" gid="$2"
	if grep -q "^${name}:" /etc/group 2>/dev/null; then
		return 0
	fi
	if command -v addgroup >/dev/null 2>&1; then
		addgroup -S -g "$gid" "$name" 2>/dev/null || addgroup "$name" 2>/dev/null || true
	fi
	if ! grep -q "^${name}:" /etc/group 2>/dev/null; then
		echo "${name}:x:${gid}:" >> /etc/group
	fi
}

ensure_user() {
	local name="$1" uid="$2" group="$3"
	if grep -q "^${name}:" /etc/passwd 2>/dev/null; then
		return 0
	fi
	if command -v adduser >/dev/null 2>&1; then
		adduser -S -D -H -u "$uid" -G "$group" -s /bin/false "$name" 2>/dev/null || true
	fi
	if ! grep -q "^${name}:" /etc/passwd 2>/dev/null; then
		echo "${name}:x:${uid}:${uid}:GFC ${name}:/var/lib/gfc-client:/bin/false" >> /etc/passwd
	fi
}

ensure_group "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID"
ensure_user "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID" "$GFC_MOSDNS_USER"
ensure_group "$GFC_SINGBOX_USER" "$GFC_SINGBOX_UID"
ensure_user "$GFC_SINGBOX_USER" "$GFC_SINGBOX_UID" "$GFC_SINGBOX_USER"

ensure_singbox_caps() {
	local bin="/usr/bin/sing-box"
	if command -v readlink >/dev/null 2>&1; then
		bin="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
	fi
	if [ -e /dev/net/tun ]; then
		chmod 666 /dev/net/tun 2>/dev/null || true
	fi
	if ! command -v setcap >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
		echo "WARN: setcap not found; installing libcap-bin..." >&2
		opkg update >/dev/null 2>&1 || true
		opkg install libcap-bin >/dev/null 2>&1 || true
	fi
	if command -v setcap >/dev/null 2>&1; then
		setcap cap_net_admin,cap_net_raw,cap_net_bind_service+ep "$bin" 2>/dev/null || \
			echo "WARN: failed to set sing-box capabilities" >&2
		if command -v getcap >/dev/null 2>&1 && ! getcap "$bin" 2>/dev/null | grep -q 'cap_net_admin'; then
			echo "WARN: sing-box capabilities not active on $bin; non-root TUN may fail" >&2
		fi
	else
		echo "WARN: setcap not found; install libcap-bin or sing-box cannot run as non-root with TUN" >&2
	fi
}

install_unbound_pkg() {
	if ! command -v opkg >/dev/null 2>&1; then
		return 0
	fi
	if command -v unbound-checkconf >/dev/null 2>&1 \
		|| command -v unbound >/dev/null 2>&1 \
		|| [ -x /usr/sbin/unbound ] \
		|| [ -x /sbin/unbound ]; then
		return 0
	fi
	echo "==> install unbound-daemon + unbound-checkconf (ImmortalWrt DNS core)"
	opkg update >/dev/null 2>&1 || true
	opkg install unbound-daemon unbound-checkconf 2>/dev/null \
		|| opkg install unbound-daemon 2>/dev/null \
		|| true
}

install_unbound_pkg

install_tc_deps() {
	if ! command -v opkg >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v tc >/dev/null 2>&1; then
		# tc-tiny → /usr/libexec/tc-tiny; /sbin/tc via ALTERNATIVES (ip-full has no tc).
		opkg install tc-tiny 2>/dev/null || true
		[ -x /usr/libexec/tc-tiny ] && [ ! -e /sbin/tc ] \
			&& ln -sf /usr/libexec/tc-tiny /sbin/tc 2>/dev/null || true
	fi
	for mod in kmod-sched-core kmod-ifb; do
		opkg install "$mod" 2>/dev/null || true
	done
}
install_tc_deps

ensure_singbox_caps

cat >"$GFC_ETC/gfc.env" <<EOF
GFC_PLATFORM=immortalwrt
GFC_ROOT=$GFC_ROOT
GFC_ETC=$GFC_ETC
GFC_LIB=$GFC_LIB
GFC_LOG_DIR=$GFC_LOG_DIR
GFC_WEB_MODE=api
GFC_CLIENT_WEB_PORT=$GFC_WEB_PORT
GFC_PROXY_MODE=${GFC_PROXY_MODE:-gateway}
GFC_ROUTING_SCHEME=${GFC_ROUTING_SCHEME:-kernel-split}
GFC_ENABLE_OUTPUT_POLICY=${GFC_ENABLE_OUTPUT_POLICY:-1}
GFC_POLICY_MARK=${GFC_POLICY_MARK:-0x2023}
GFC_POLICY_TABLE=${GFC_POLICY_TABLE:-2022}
GFC_WAN_IFACE=${GFC_WAN_IFACE:-eth0}
GFC_TUN_INTERFACE=${GFC_TUN_INTERFACE:-gfctun}
GFC_REDIRECT_PORT=${GFC_REDIRECT_PORT:-11800}
GFC_EXT_CONST_IPS=${GFC_EXT_CONST_IPS:-8.8.4.4,8.8.8.8,1.1.1.1,1.0.0.1}
GFC_SSH_PORT=${GFC_SSH_PORT:-212}
GFC_MOSDNS_USER=$GFC_MOSDNS_USER
GFC_MOSDNS_UID=${GFC_MOSDNS_UID}
GFC_SINGBOX_USER=$GFC_SINGBOX_USER
GFC_SINGBOX_UID=${GFC_SINGBOX_UID}
EOF
chmod 600 "$GFC_ETC/gfc.env"

for svc in gfc-api gfc-agent gfc-unbound gfc-sing-box gfc-routing; do
	cp "$INIT_SRC/$svc" "/etc/init.d/$svc"
	chmod +x "/etc/init.d/$svc"
done

chmod +x "$GFC_ROOT"/deploy/immortalwrt/*.sh 2>/dev/null || true
chmod +x "$GFC_ROOT"/deploy/apply-tc-htb.sh 2>/dev/null || true

# Stock OpenWrt unbound uses UCI (recursive from root) and ignores GFC conf.
# Legacy gfc-mosdns / package mosdns are not used for LAN DNS.
/etc/init.d/unbound stop 2>/dev/null || true
/etc/init.d/unbound disable 2>/dev/null || true
/etc/init.d/gfc-mosdns stop 2>/dev/null || true
/etc/init.d/gfc-mosdns disable 2>/dev/null || true
/etc/init.d/mosdns stop 2>/dev/null || true
/etc/init.d/mosdns disable 2>/dev/null || true

_fw4_sh="$GFC_ROOT/deploy/immortalwrt/disable-immortalwrt-fw4.sh"
if [ -f "$_fw4_sh" ]; then
	sh "$_fw4_sh" || true
else
	/etc/init.d/firewall stop 2>/dev/null || true
	/etc/init.d/firewall disable 2>/dev/null || true
fi

_ensure_unbound_dirs() {
	_sh="$GFC_ROOT/deploy/immortalwrt/ensure-unbound-dirs.sh"
	[ -f "$_sh" ] && sh "$_sh" || mkdir -p /etc/unbound/conf.d /var/lib/unbound
}

if [ "${GFC_SAFE_INSTALL:-0}" = "1" ]; then
	echo "safe install: bootstrap reapply skipped (GFC_SAFE_INSTALL=1)"
elif [ -x /usr/bin/gfc-bootstrap ]; then
	_ensure_unbound_dirs
	run_bootstrap() {
		GFC_PLATFORM=immortalwrt \
		GFC_ROOT="$GFC_ROOT" \
		GFC_ETC="$GFC_ETC" \
		GFC_LIB="$GFC_LIB" \
		GFC_LOG_DIR="$GFC_LOG_DIR" \
		gfc-bootstrap "$@"
	}
	_bootstrap_ok() {
		if [ -f "$GFC_LIB/state/config_bundle.json" ]; then
			run_bootstrap --reapply
			return $?
		fi
		run_bootstrap
	}
	if ! _bootstrap_ok; then
		echo "WARN: bootstrap failed; retry after ensure-unbound-dirs" >&2
		_ensure_unbound_dirs
		if ! _bootstrap_ok; then
			echo "WARN: bootstrap still failed; gfc-unbound may not start until gfc-bootstrap succeeds" >&2
		fi
	fi
fi

# unbound owns DNS :53; dnsmasq is DHCP-only and advertises LAN gateway as DNS.
if command -v uci >/dev/null 2>&1; then
	cp /etc/config/dhcp "/etc/config/dhcp.bak.gfc.$(date +%s)" 2>/dev/null || true
fi
_dns_sh="$GFC_ROOT/deploy/immortalwrt/configure-dnsmasq-dhcp.sh"
if [ -f "$_dns_sh" ]; then
	sh "$_dns_sh"
fi

/etc/init.d/gfc-api enable
/etc/init.d/gfc-agent enable
/etc/init.d/gfc-unbound enable
/etc/init.d/gfc-sing-box enable
/etc/init.d/gfc-routing enable

service_restart() {
	local svc="$1"
	"/etc/init.d/$svc" stop 2>/dev/null || true
	sleep 1
	"/etc/init.d/$svc" start
}

service_restart gfc-api
service_restart gfc-unbound || true
# DHCP only; must run after UCI port=0 so it does not fight unbound for :53.
/etc/init.d/dnsmasq restart || true
service_restart gfc-agent
start_dataplane() {
	if [ "${GFC_SKIP_DATAPLANE:-0}" = "1" ]; then
		echo "NOTE: GFC_SKIP_DATAPLANE=1, gfc-sing-box / gfc-routing not started"
		return 0
	fi
	# Base LAN path: DNS hijack + WAN NAT must exist even before activation.
	/etc/init.d/gfc-routing start 2>/dev/null || \
		/usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh start 2>/dev/null || true
	if [ ! -x /usr/bin/sing-box ]; then
		echo "NOTE: /usr/bin/sing-box missing; gfc-routing base rules applied" >&2
		return 0
	fi
	if [ ! -f /etc/gfc-client/sing-box.json ]; then
		echo "NOTE: no sing-box.json; gfc-routing base rules applied (activate for proxy)" >&2
		return 0
	fi
	service_restart gfc-sing-box || true
	/etc/init.d/gfc-routing start 2>/dev/null || true
}
start_dataplane

_verify_sh="$GFC_ROOT/deploy/immortalwrt/verify-dataplane-dns.sh"
if [ -f "$_verify_sh" ]; then
	sh "$_verify_sh" || echo "WARN: dataplane verify failed — see messages above" >&2
fi

echo "GFC runtime installed. API: http://127.0.0.1:${GFC_WEB_PORT}/api/v1/status"
