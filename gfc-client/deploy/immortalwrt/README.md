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
