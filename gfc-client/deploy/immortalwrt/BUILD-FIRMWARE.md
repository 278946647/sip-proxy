# GFC ImmortalWrt 固件构建

> **会话状态 / 卡点 / 踩坑全集：** [`FIRMWARE-BUILD-HANDOFF.md`](FIRMWARE-BUILD-HANDOFF.md)  
> **Cursor 规则：** [`.cursor/rules/gfc-firmware-build.mdc`](../../../.cursor/rules/gfc-firmware-build.mdc)

## 根因总结

| 现象 | 原因 |
|------|------|
| `oldconfig` / 全量 `make` 后 `.config` 无 GFC | `syncconfig` 删除 Kconfig 不认识的符号 |
| `packageinfo` 有 gfc，manifest 无 gfc | `.config` 未选中 **或** rootfs 用了旧缓存 |
| 有 gfc-client ipk 但镜像无 GFC | ipk 编过 ≠ 装进 rootfs |

## 推荐：一条脚本重建（构建机 gfcbuild）

```bash
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-buildvcs=false

cd /opt/gfc/sip-proxy && git pull

chmod +x "$GFC_REPO/deploy/immortalwrt/scripts/"*.sh
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

成功标志：

```bash
grep -i gfc "$IMT_SRC/bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
# 必须有 gfc-client 和 luci-app-gfc
```

## 手工步骤（等价）

```bash
bash "$GFC_REPO/deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh" all

# 写入 .config — 不要 oldconfig / defconfig
sed -i '/CONFIG_PACKAGE_gfc-client/d;/CONFIG_PACKAGE_luci-app-gfc/d' "$IMT_SRC/.config"
cat "$GFC_REPO/deploy/immortalwrt/config/gfc-packages.config" >> "$IMT_SRC/.config"
grep CONFIG_PACKAGE_gfc-client "$IMT_SRC/.config"

# 强制清空 rootfs 缓存
rm -rf "$IMT_SRC/build_dir/target-x86_64_musl/root-"*
rm -f "$IMT_SRC/build_dir/target-x86_64_musl/stamp/.rootfs_installed"

cd "$IMT_SRC"
make package/install -j1 V=s          # 必须先装 rootfs，再编镜像
make target/linux/install -j1 V=s     # 勿在删 root-* 后只跑 target/install

grep -i gfc bin/targets/x86/64/*.manifest
```

## 旧固件能否删除？

**可以删**（无 GFC 的镜像没有保留价值）：

```bash
# 无 GFC 的旧产物（示例）
rm -f /opt/gfc/dist/gfc-os-v1/immortalwrt-*.img.gz
rm -f /opt/gfc/dist/gfc-os-v1/*.vmdk
rm -f /opt/gfc/dist/gfc-os-v1/*.img
rm -f /dev/sdX   # 若误 dd 生成的文件

# 保留（重编快）：
#   /opt/gfc/immortalwrt/dl/
#   /opt/gfc/immortalwrt/staging_dir/
#   /opt/gfc/immortalwrt/build_dir/host/
#   /opt/gfc/immortalwrt/build_dir/toolchain-*
```

manifest **有 gfc** 之后的新 `img.gz` / `vmdk` 再拷到 `dist/` 发布。

## 禁止

- `make defconfig` 在选 GFC 之后
- `yes | make oldconfig` 在写入 GFC 之后
- 不查 manifest 就刷机 / 做 vmdk

## 产物

- 固件：`bin/targets/x86/64/immortalwrt-x86-64-generic-ext4-combined-efi.img.gz`
- 清单：`bin/targets/x86/64/immortalwrt-x86-64-generic.manifest`
