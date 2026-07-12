#!/bin/sh
# GFC OEM: assign WAN = first physical NIC, LAN (br-lan) = last physical NIC.
# ImmortalWrt x86 stock often does the opposite (lan=eth0, wan=eth1).
#
# Discovers eth*/en* at runtime — no hardcoded PCI board map.
# Single NIC: leave UCI alone (cannot split wan/lan safely).
set -eu

GFC_ETC="${GFC_ETC:-/etc/gfc-client}"
ENV_FILE="${GFC_ENV_FILE:-$GFC_ETC/gfc.env}"

list_phys_eth() {
	# Prefer kernel ethN in numeric order; fall back to en*.
	local n found=0
	for n in $(ls -1 /sys/class/net 2>/dev/null | grep -E '^eth[0-9]+$' | sed 's/^eth//' | sort -n | sed 's/^/eth/'); do
		[ -d "/sys/class/net/$n/device" ] || continue
		echo "$n"
		found=1
	done
	[ "$found" = "1" ] && return 0
	for n in $(ls -1 /sys/class/net 2>/dev/null | grep -E '^(enp|ens|eno)[0-9a-z]+$' | sort); do
		[ -d "/sys/class/net/$n/device" ] || continue
		echo "$n"
	done
}

env_set() {
	local key="$1" val="$2" f="$ENV_FILE"
	mkdir -p "$(dirname "$f")"
	touch "$f"
	if grep -q "^${key}=" "$f" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$f"
	else
		echo "${key}=${val}" >>"$f"
	fi
}

if ! command -v uci >/dev/null 2>&1; then
	echo "configure-network-ports: uci missing, skip"
	exit 0
fi

# Build space-separated NIC list without relying on xargs.
nics=""
count=0
for n in $(list_phys_eth); do
	nics="${nics}${nics:+ }$n"
	count=$((count + 1))
done

echo "configure-network-ports: discovered ($count): $nics"

if [ "$count" -lt 2 ]; then
	echo "configure-network-ports: need >=2 NICs to split wan/lan; leave UCI as-is"
	# Still sync GFC_WAN_IFACE from UCI wan if present.
	wan_uci="$(uci -q get network.wan.device 2>/dev/null || true)"
	[ -n "$wan_uci" ] && env_set GFC_WAN_IFACE "$wan_uci"
	exit 0
fi

wan_if="$(echo "$nics" | awk '{print $1}')"
lan_if="$(echo "$nics" | awk '{print $NF}')"

echo "configure-network-ports: wan=$wan_if lan_port=$lan_if"

# WAN: dhcp on first NIC
uci -q delete network.wan
uci set network.wan=interface
uci set network.wan.proto='dhcp'
uci set network.wan.device="$wan_if"
uci set network.wan.metric='10'

# Ensure br-lan device exists and only uses last NIC as port.
if ! uci -q get network.@device[0] >/dev/null 2>&1; then
	uci add network device >/dev/null
fi

# Find or create device section named br-lan
br_sec=""
i=0
while uci -q get "network.@device[$i]" >/dev/null 2>&1; do
	name="$(uci -q get "network.@device[$i].name" 2>/dev/null || true)"
	if [ "$name" = "br-lan" ]; then
		br_sec="network.@device[$i]"
		break
	fi
	i=$((i + 1))
done
if [ -z "$br_sec" ]; then
	br_sec="network.$(uci add network device)"
fi
uci set "${br_sec}.name"='br-lan'
uci set "${br_sec}.type"='bridge'
uci -q delete "${br_sec}.ports"
uci add_list "${br_sec}.ports"="$lan_if"

# LAN interface
if ! uci -q get network.lan >/dev/null 2>&1; then
	uci set network.lan=interface
fi
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
# Keep existing IP if already set; otherwise default gateway for OEM.
if [ -z "$(uci -q get network.lan.ipaddr 2>/dev/null || true)" ]; then
	uci set network.lan.ipaddr='192.168.1.1'
	uci set network.lan.netmask='255.255.255.0'
fi

uci commit network

env_set GFC_WAN_IFACE "$wan_if"
# Bridge name for nft iifname (not the port).
env_set GFC_LAN_IFACE "br-lan"

echo "configure-network-ports: UCI wan=$wan_if br-lan ports=$lan_if; gfc.env updated"

# Apply if network service exists (firstboot may restart later).
if [ -x /etc/init.d/network ]; then
	/etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true
fi

exit 0
