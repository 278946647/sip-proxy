# GFC ImmortalWrt image overlay

## `files/`

Linked into ImmortalWrt tree as `$IMT_SRC/files` during `rebuild-gfc-image.sh`.

OpenWrt `prepare_rootfs` copies these into the final rootfs. Primary first-boot scripts:

| Path | Role |
|------|------|
| `files/etc/uci-defaults/95-gfc-rootpt-resize` | Grow root **partition**, reboot (OpenWrt expand_root phase 1) |
| `files/etc/uci-defaults/96-gfc-rootfs-resize` | Grow root **filesystem** with resize2fs, reboot (phase 2) |
| `files/etc/uci-defaults/99-gfc-firstboot` | One-shot OEM bring-up (fw4 off, dnsmasq port=0, enable GFC services, bootstrap) |

The same scripts are also installed by the `gfc-client` ipk under `/etc/uci-defaults/` so feed-only installs get firstboot without the overlay.

## Rebuild

```bash
export IMT_SRC=/opt/gfc/immortalwrt GFC_REPO=/opt/gfc/sip-proxy/gfc-client
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

After flash:

- Expand log (persistent): `/etc/gfc-client/expand-rootfs.log`
- Firstboot log: `/tmp/gfc-firstboot.log`
- DHCP hotplug log: `/tmp/gfc-dnsmasq-hotplug.log`

Expect **1–2 automatic reboots** while disk expand completes. Scripts are removed from `/etc/uci-defaults/` only after each phase succeeds (exit 0).
