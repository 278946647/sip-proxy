# GFC Client on ImmortalWrt

This adapter keeps the existing Vue UI and Go API while replacing the Linux
system integration layer with ImmortalWrt/OpenWrt primitives.

## Runtime Layout

- `/usr/bin/gfc-api`: local web/API service.
- `/usr/bin/gfc-agent`: control-plane polling agent.
- `/usr/bin/gfc-bootstrap`: first boot, dataplane reapply, and network apply helper.
- `/usr/lib/gfc-client/web`: prebuilt Vue static UI.
- `/etc/gfc-client`: device config, rendered sing-box/mosdns configs, network JSON.
- `/var/lib/gfc-client`: local state, sqlite DB, rule data, backups.

## Build with ImmortalWrt SDK

Build the web UI before packaging:

```sh
cd gfc-client
bash deploy/build-web.sh
```

Copy or symlink `deploy/immortalwrt/package` into the SDK package tree, then build
with the source path:

```sh
cd /path/to/immortalwrt-sdk
ln -s /path/to/gfc-client/deploy/immortalwrt/package package/gfc-client
make package/gfc-client/compile V=s GFC_CLIENT_SRC=/path/to/gfc-client
```

## First Boot

```sh
opkg install gfc-client_*.ipk
# ImmortalWrt 25.12+:
# apk add --allow-untrusted ./gfc-client-*.apk
/etc/init.d/gfc-api start
/etc/init.d/gfc-agent start
```

The package enables these procd services:

- `gfc-api`
- `gfc-agent`
- `gfc-mosdns`
- `gfc-sing-box`
- `gfc-routing`

## Network Apply

The existing UI can keep calling the same API endpoints. On ImmortalWrt, the Go
backend writes UCI config directly and restarts:

- `network`
- `dnsmasq`
- `firewall`

For CLI recovery:

```sh
GFC_PLATFORM=immortalwrt gfc-bootstrap --apply-network
```

Network changes should be tested with a rollback plan on the target hardware,
especially when changing LAN bridge members or VLANs.

## Manual Runtime Install

For early device testing, compile on Ubuntu/VM and upload binaries plus `deploy`
and `share` directories:

```sh
scp bin/gfc-api bin/gfc-agent bin/gfc-bootstrap root@192.168.1.1:/usr/bin/
scp -r deploy share root@192.168.1.1:/usr/lib/gfc-client/
```

Then run on ImmortalWrt:

```sh
chmod +x /usr/bin/gfc-api /usr/bin/gfc-agent /usr/bin/gfc-bootstrap
chmod +x /usr/lib/gfc-client/deploy/immortalwrt/*.sh
/usr/lib/gfc-client/deploy/immortalwrt/install-runtime.sh
```

## DNS Ownership

The safe default is to keep `dnsmasq` on port 53 for DHCP/LAN compatibility and
forward DNS queries to GFC mosdns:

```text
LAN clients -> dnsmasq :53 -> mosdns 127.0.0.1:1053 -> upstream DNS
```

`install-runtime.sh` applies this with UCI:

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp
```

## LuCI App Testing

The first LuCI app version lives in `deploy/immortalwrt/luci-app-gfc` and adds:

- Overview
- Activation
- Nodes
- Policy
- Services
- DNS
- Diagnostics
- Logs

For manual testing after uploading `deploy` to the device:

```sh
/usr/lib/gfc-client/deploy/immortalwrt/install-luci-app.sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Then open:

```text
http://<router-ip>/cgi-bin/luci/admin/gfc
```
