# GFC Client on ImmortalWrt

This adapter keeps the existing Vue UI and Go API while replacing the Linux
system integration layer with ImmortalWrt/OpenWrt primitives.

## Runtime Layout

- `/usr/bin/gfc-api`: local web/API service.
- `/usr/bin/gfc-agent`: control-plane polling agent.
- `/usr/bin/gfc-bootstrap`: first boot, dataplane reapply, and network apply helper.
- `/usr/lib/gfc-client/web`: prebuilt Vue static UI.
- `/etc/gfc-client`: device config, rendered sing-box/unbound configs, network JSON.
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
- `gfc-unbound`
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

By default, GFC preserves the current ImmortalWrt LAN/DHCP configuration from
UCI, for example the stock `192.168.1.1/24` LAN and `192.168.1.0/24` DHCP pool.
It does not switch LAN to `192.168.68.1/24` unless a GFC network config is
explicitly saved and applied. Even when `gfc-bootstrap --apply-network` runs,
GFC will not write `network.lan` or `dhcp.lan` unless `GFC_MANAGE_LAN=1` is set
or the saved network config contains `manageLan: true`.

WAN is handled the same way:

- Without `/etc/gfc-client/network-wan.json`, the first `gfc-bootstrap --apply-network`
  **imports the current UCI `network.wan` into `network-wan.json`** and does not
  overwrite WAN unless that file already existed.
- To force WAN apply without a saved file, set `GFC_MANAGE_WAN=1`.
- Before any WAN UCI write, `/etc/config/network` is snapshotted under
  `/var/lib/gfc-client/backups/network-<timestamp>/`.
- Roll back with:

```sh
gfc-bootstrap --rollback-network
```

完整契约见 [`docs/NETWORK_APPLY.md`](../../docs/NETWORK_APPLY.md)。

底层变更流程见 [`docs/DATAPLANE_CHANGE.md`](../../docs/DATAPLANE_CHANGE.md)。

`network-wan.json` WAN modes:

| mode | JSON fields |
|------|-------------|
| `static` | `address`, `netmask`, `gateway`, `dns1`, `dns2` |
| `dhcp` | clears static/pppoe UCI leftovers |
| `pppoe` | `username`, `password`; clears static UCI leftovers |

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

## Runtime Tarball

For repeatable field testing without the SDK, build a runtime tarball on
Ubuntu/VM:

```sh
cd gfc-client
# x86_64
GOARCH=amd64 bash deploy/immortalwrt/pack-runtime.sh

# aarch64
GOARCH=arm64 bash deploy/immortalwrt/pack-runtime.sh
```

Upload and install on the device:

```sh
scp dist/gfc-immortalwrt-runtime-*.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1
cd /tmp
tar xzf gfc-immortalwrt-runtime-*.tar.gz
cd gfc-immortalwrt-runtime-*
./install.sh
```

This runtime tarball intentionally does not include `sing-box` binaries;
install or upload them separately to `/usr/bin/sing-box`.

## DNS Ownership

```text
LAN clients -> dnsmasq (DHCP only, port=0) -> DHCP option 6 = gateway
             -> unbound :53 (GFC gfc-unbound)
```

`configure-dnsmasq-dhcp.sh` sets `dhcp.@dnsmasq[0].port=0` and advertises the LAN
gateway as DNS. GFC nft DNS hijack redirects external DNS to local unbound.

**fw4:** Stock ImmortalWrt `firewall` (fw4) must be **disabled** — GFC `gfc-routing` owns
`inet nat` / `inet gfc` / `inet gfc_dns_hijack`. See `disable-immortalwrt-fw4.sh`.

## Dataplane Split

The ImmortalWrt dataplane uses `inet gfc` nft tables and kernel-split sing-box:

```text
LAN -> nft prerouting (TO_CN / bypass / ext) -> direct or fwmark 0x2023 -> gfctun
```

CN IP set source:

```text
/usr/lib/gfc-client/share/easymosdns/rules/china_ip_list.txt
```

For audit and troubleshooting, `gfc-routing.sh` writes:

```text
/etc/gfc-client/nftables-cn-ip.set
/etc/gfc-client/nftables-cn-ip-load.nft
```

Check dataplane state with:

```sh
/usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh status
nft list set inet gfc_client_mangle cn_ip
```

## Port 80 Device Activation (No Login)

ImmortalWrt keeps **uhttpd on :80** for system login. GFC device activation is served
outside LuCI auth:

| URL | Purpose |
|-----|---------|
| `http://<device-ip>/` | Redirects to activation portal |
| `http://<device-ip>/gfc/activate.html` | Line-code flash + activation status |
| `http://<device-ip>/cgi-bin/luci/admin/gfc` | **GFC 管理界面（LuCI）** |
| `http://127.0.0.1:8080/api/v1/` | gfc-api 本地 API（LuCI 后端，无 Web UI） |

Install with `install-luci-app.sh`, which deploys:

- `/www/gfc/activate.html` — external activation UI
- `/www/cgi-bin/gfc-activation` — same-origin CGI proxy to `gfc-api` on `127.0.0.1:8080`

## LuCI App Testing

The first LuCI app version lives in `deploy/immortalwrt/luci-app-gfc` and adds:

- Overview
- Activation status (flash moved to `/gfc/activate.html`)
- Nodes
- Policy
- Dataplane
- Integration
- Settings
- Network
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
