#!/bin/sh
set -eu

GFC_ROOT="${GFC_ROOT:-/usr/lib/gfc-client}"
GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
GFC_LIB="${GFC_LIB:-/var/lib/gfc-client}"
GFC_LOG_DIR="${GFC_LOG_DIR:-/var/log/gfc-client}"
GFC_MOSDNS_USER="${GFC_MOSDNS_USER:-mosdns}"
GFC_MOSDNS_UID="${GFC_MOSDNS_UID:-65353}"
GFC_SINGBOX_USER="${GFC_SINGBOX_USER:-singbox}"
GFC_SINGBOX_UID="${GFC_SINGBOX_UID:-65354}"
INIT_SRC="${GFC_ROOT}/deploy/immortalwrt/package/files/etc/init.d"

stop_service() {
	local svc="$1"
	"/etc/init.d/$svc" stop 2>/dev/null || true
}

start_service() {
	local svc="$1"
	"/etc/init.d/$svc" start 2>/dev/null || true
}

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

env_set() {
	local key="$1" value="$2" file="$GFC_ETC/gfc.env"
	mkdir -p "$GFC_ETC"
	touch "$file"
	if grep -q "^${key}=" "$file" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${value}|" "$file"
	else
		echo "${key}=${value}" >> "$file"
	fi
}

step() { echo "==> [upgrade] $*"; }

install_unbound_pkg() {
	if [ "${GFC_SKIP_OPKG:-0}" = "1" ]; then
		step "skip opkg (GFC_SKIP_OPKG=1)"
		return 0
	fi
	if ! command -v opkg >/dev/null 2>&1; then
		return 0
	fi
	if command -v unbound-checkconf >/dev/null 2>&1 \
		|| command -v unbound >/dev/null 2>&1 \
		|| [ -x /usr/sbin/unbound ] \
		|| [ -x /sbin/unbound ]; then
		return 0
	fi
	step "opkg install unbound-daemon (may hang if mirror/network slow; Ctrl+C and retry with GFC_SKIP_OPKG=1 if already installed)"
	opkg update >/dev/null 2>&1 || true
	# ImmortalWrt/OpenWrt: no meta package "unbound"; use daemon + checkconf.
	opkg install unbound-daemon unbound-checkconf 2>/dev/null \
		|| opkg install unbound-daemon 2>/dev/null \
		|| true
	# Keep GFC-rendered /etc/unbound/unbound.conf when opkg warns about conffile drift.
	if [ -f /etc/unbound/unbound.conf-opkg ] && [ -f /etc/gfc-client/gfc.env ]; then
		echo "    kept GFC unbound.conf (opkg default at unbound.conf-opkg)"
	fi
}

step "optional unbound packages"
install_unbound_pkg

install_tc_deps() {
	if [ "${GFC_SKIP_OPKG:-0}" = "1" ]; then
		return 0
	fi
	if ! command -v opkg >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v tc >/dev/null 2>&1; then
		opkg install tc-tiny 2>/dev/null || opkg install ip-full 2>/dev/null || true
	fi
	for mod in kmod-sched-core kmod-sched-htb kmod-ifb; do
		opkg install "$mod" 2>/dev/null || true
	done
}
step "optional tc/htb packages"
install_tc_deps

step "stop gfc services"
stop_service gfc-agent
stop_service gfc-api
stop_service gfc-unbound
stop_service gfc-mosdns
stop_service gfc-sing-box
stop_service gfc-routing

pkill gfc-api 2>/dev/null || true
pkill gfc-agent 2>/dev/null || true
pkill gfc-bootstrap 2>/dev/null || true
sleep 1

step "install binaries"
for bin in gfc-api gfc-agent gfc-bootstrap; do
	if [ -f "/tmp/$bin" ]; then
		mv "/tmp/$bin" "/usr/bin/$bin"
		chmod +x "/usr/bin/$bin"
	fi
done

step "sync deploy scripts + gfc.env"
chmod +x /usr/lib/gfc-client/deploy/immortalwrt/*.sh 2>/dev/null || true
find /usr/lib/gfc-client/deploy -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

ensure_group "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID"
ensure_user "$GFC_MOSDNS_USER" "$GFC_MOSDNS_UID" "$GFC_MOSDNS_USER"
ensure_group "$GFC_SINGBOX_USER" "$GFC_SINGBOX_UID"
ensure_user "$GFC_SINGBOX_USER" "$GFC_SINGBOX_UID" "$GFC_SINGBOX_USER"
env_set GFC_ROUTING_SCHEME "${GFC_ROUTING_SCHEME:-kernel-split}"
env_set GFC_WEB_MODE api
env_set GFC_ENABLE_OUTPUT_POLICY 1
env_set GFC_POLICY_MARK "${GFC_POLICY_MARK:-0x2023}"
env_set GFC_POLICY_TABLE "${GFC_POLICY_TABLE:-2022}"
env_set GFC_WAN_IFACE "${GFC_WAN_IFACE:-eth0}"
env_set GFC_TUN_INTERFACE "${GFC_TUN_INTERFACE:-gfctun}"
env_set GFC_REDIRECT_PORT "${GFC_REDIRECT_PORT:-11800}"
env_set GFC_EXT_CONST_IPS "${GFC_EXT_CONST_IPS:-8.8.4.4,8.8.8.8,1.1.1.1,1.0.0.1}"
env_set GFC_SSH_PORT "${GFC_SSH_PORT:-212}"
env_set GFC_MOSDNS_USER "$GFC_MOSDNS_USER"
env_set GFC_MOSDNS_UID "$GFC_MOSDNS_UID"
env_set GFC_SINGBOX_USER "$GFC_SINGBOX_USER"
env_set GFC_SINGBOX_UID "$GFC_SINGBOX_UID"

ensure_singbox_caps() {
	local bin="/usr/bin/sing-box"
	if command -v readlink >/dev/null 2>&1; then
		bin="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
	fi
	if [ -e /dev/net/tun ]; then
		chmod 666 /dev/net/tun 2>/dev/null || true
	fi
	if ! command -v setcap >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1 \
		&& [ "${GFC_SKIP_OPKG:-0}" != "1" ]; then
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

step "sing-box capabilities"
ensure_singbox_caps

step "install procd init scripts"
if [ -d "$INIT_SRC" ]; then
	for svc in gfc-api gfc-agent gfc-unbound gfc-sing-box gfc-routing; do
		cp "$INIT_SRC/$svc" "/etc/init.d/$svc"
		chmod +x "/etc/init.d/$svc"
	done
fi

_ensure_unbound_dirs() {
	_sh="$GFC_ROOT/deploy/immortalwrt/ensure-unbound-dirs.sh"
	[ -f "$_sh" ] && sh "$_sh" || mkdir -p /etc/unbound/conf.d /var/lib/unbound
}

# Stock unbound (UCI recursive) must not own :53; GFC uses gfc-unbound + GFC conf.
/etc/init.d/unbound stop 2>/dev/null || true
/etc/init.d/unbound disable 2>/dev/null || true
/etc/init.d/gfc-mosdns stop 2>/dev/null || true
/etc/init.d/gfc-mosdns disable 2>/dev/null || true

start_dataplane() {
	if [ "${GFC_SKIP_DATAPLANE:-0}" = "1" ]; then
		echo "NOTE: GFC_SKIP_DATAPLANE=1, gfc-sing-box / gfc-routing not started"
		return 0
	fi
	if [ ! -x /usr/bin/sing-box ]; then
		echo "NOTE: /usr/bin/sing-box missing; install sing-box before starting gfc-sing-box" >&2
		return 0
	fi
	if [ ! -f /etc/gfc-client/sing-box.json ]; then
		echo "NOTE: no /etc/gfc-client/sing-box.json yet; activate device first, then apply config" >&2
		return 0
	fi
	step "start gfc-sing-box + gfc-routing"
	start_service gfc-sing-box
	start_service gfc-routing
	# sing-box creates gfctun asynchronously; retry policy route once TUN is up.
	(
		i=0
		while [ "$i" -lt 30 ]; do
			if ip link show "${GFC_TUN_INTERFACE:-gfctun}" >/dev/null 2>&1; then
				/usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh start >/dev/null 2>&1 || true
				break
			fi
			i=$((i + 1))
			sleep 1
		done
	) &
}

step "bootstrap / reapply dataplane config"
_ensure_unbound_dirs
if [ "${GFC_SAFE_INSTALL:-0}" = "1" ]; then
	echo "safe install: bootstrap reapply skipped (GFC_SAFE_INSTALL=1)"
elif [ -x /usr/bin/gfc-bootstrap ]; then
	run_bootstrap() {
		GFC_PLATFORM=immortalwrt \
		GFC_ROOT="$GFC_ROOT" \
		GFC_ETC="$GFC_ETC" \
		GFC_LIB="$GFC_LIB" \
		GFC_LOG_DIR="$GFC_LOG_DIR" \
		gfc-bootstrap "$@"
	}
	if [ -f "$GFC_LIB/state/config_bundle.json" ]; then
		run_bootstrap --reapply || echo "WARN: active dataplane reapply failed; keeping existing config" >&2
	else
		run_bootstrap || true
	fi
fi

step "install LuCI app"
if [ -x /usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh ]; then
	/usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh || true
fi

step "clear LuCI cache"
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

# unbound owns DNS :53; dnsmasq is DHCP-only and advertises LAN gateway as DNS.
# Always invoke via sh (file may lack +x after tar extract).
_dns_sh=""
if [ -f /usr/lib/gfc-client/deploy/immortalwrt/configure-dnsmasq-dhcp.sh ]; then
	_dns_sh=/usr/lib/gfc-client/deploy/immortalwrt/configure-dnsmasq-dhcp.sh
elif [ -f "$GFC_ROOT/deploy/immortalwrt/configure-dnsmasq-dhcp.sh" ]; then
	_dns_sh="$GFC_ROOT/deploy/immortalwrt/configure-dnsmasq-dhcp.sh"
fi
step "configure dnsmasq DHCP (port=0)"
if [ -n "$_dns_sh" ]; then
	sh "$_dns_sh"
fi

step "start services"
start_service gfc-api
start_service gfc-unbound
/etc/init.d/dnsmasq restart 2>/dev/null || true
start_service gfc-agent
start_dataplane

step "restore reverse ssh tunnel when enabled"
if [ -x /etc/init.d/gfc-reverse-ssh ]; then
	if pidof autossh >/dev/null 2>&1 || /etc/init.d/gfc-reverse-ssh running 2>/dev/null; then
		/etc/init.d/gfc-reverse-ssh restart 2>/dev/null || true
	fi
fi
touch /var/run/gfc-restore-reverse-ssh 2>/dev/null || true

for svc in gfc-api gfc-agent gfc-unbound gfc-sing-box gfc-routing; do
	/etc/init.d/"$svc" enable 2>/dev/null || true
done

echo "GFC runtime upgraded"
