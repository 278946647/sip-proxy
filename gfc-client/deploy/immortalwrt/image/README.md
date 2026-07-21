# GFC ImmortalWrt image overlay

## `files/`

Linked into ImmortalWrt tree as `$IMT_SRC/files` during `rebuild-gfc-image.sh`.

OpenWrt `prepare_rootfs` copies these into the final rootfs. Primary first-boot scripts:

| Path | Role |
|------|------|
| `files/etc/uci-defaults/93-gfc-vga-console` | Disable ttyS*/hvc* getty; keep tty1 askfirst (not respawn) |
| `files/etc/uci-defaults/95-gfc-rootpt-resize` | Grow root **partition**, reboot (OpenWrt expand_root phase 1) |
| `files/etc/uci-defaults/96-gfc-rootfs-resize` | Grow root **filesystem** with resize2fs, reboot (phase 2) |
| `files/etc/uci-defaults/99-gfc-firstboot` | One-shot OEM bring-up (fw4 off, dnsmasq port=0, enable GFC services, bootstrap) |
| `files/etc/opkg/distfeeds.conf` | Official ImmortalWrt feeds via **files overlay only** (not gfc-client ipk — `base-files` owns the path) |
| `files/etc/sysctl.d/12-gfc-bbr.conf` | Enable TCP BBR + fq (needs `kmod-tcp-bbr` / `kmod-sched` in image) |

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

## VMware / VGA / bare-metal console

ImmortalWrt **24.10** x86 `image/Makefile` *always* appends `console=ttyS0` last
(`CONFIG_GRUB_SERIAL` no longer exists). Linux then uses serial as `/dev/console`,
so the monitor looks stuck after `Run /sbin/init`.

OEM fix (r23+): `rebuild-gfc-image.sh` injects `GFC_VGA_CONSOLE_LAST` so cmdline ends
with `console=tty1`. Verify:

```bash
zcat bin/targets/x86/64/*combined*efi*.img.gz | strings | grep -E 'console=tty'
# GOOD: ... console=ttyS0,... console=tty1
# BAD:  ... console=tty1 console=ttyS0,...   (serial last)
```

`qemu-img convert` / Rufus **cannot** fix this — must rebuild.
