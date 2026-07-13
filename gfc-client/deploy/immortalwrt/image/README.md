# GFC ImmortalWrt image overlay

## `files/`

Linked into ImmortalWrt tree as `$IMT_SRC/files` during `rebuild-gfc-image.sh`.

OpenWrt `prepare_rootfs` copies these into the final rootfs. Primary first-boot script:

| Path | Role |
|------|------|
| `files/etc/uci-defaults/96-gfc-expand-rootfs` | Grow root partition + ext4 to fill disk (needs `resize2fs` package, not e2fsprogs alone) |
| `files/etc/uci-defaults/99-gfc-firstboot` | One-shot OEM bring-up (fw4 off, dnsmasq port=0, enable GFC services, bootstrap) |

The same scripts are also installed by the `gfc-client` ipk under `/etc/uci-defaults/` so feed-only installs get firstboot without the overlay.

## Rebuild

```bash
export IMT_SRC=/opt/gfc/immortalwrt GFC_REPO=/opt/gfc/sip-proxy/gfc-client
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

After flash:

- Expand log: `/tmp/gfc-expand-rootfs.log`
- Firstboot log: `/tmp/gfc-firstboot.log`

Scripts are removed from `/etc/uci-defaults/` on success (exit 0).
