# GFC ImmortalWrt 固件构建（永久修复说明）

## 根因：为什么 `oldconfig` 会删掉 `CONFIG_PACKAGE_gfc-client=y`？

1. **无效 DEPENDS**（已修复）：`gfc-client` 曾依赖 `sqlite3-cli`，ImmortalWrt feed 中不存在该包名 → 包无法进入 Kconfig → `make oldconfig` 删除未知符号。
2. **软链到 `package/gfc/` 不稳定**：应使用 **`feeds.conf` 的 `src-link gfc`**，再 `feeds install`，包会出现在 `package/feeds/gfc/` 并被 Kconfig 正确识别。

## 一次性接入（构建机）

```bash
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export PATH=/usr/local/go/bin:$PATH

cd "$GFC_REPO"
git pull

# ipk 安装需要 gfc.env（仓库提供 example）
ENV_DIR="$GFC_REPO/deploy/immortalwrt/package/files/etc/gfc-client"
test -f "$ENV_DIR/gfc.env" || cp "$ENV_DIR/gfc.env.example" "$ENV_DIR/gfc.env"

bash deploy/immortalwrt/scripts/setup-immortalwrt-feed.sh all
```

验证（**必须通过**）：

```bash
grep CONFIG_PACKAGE_gfc-client "$IMT_SRC/.config"
grep gfc-client "$IMT_SRC/tmp/.packageinfo"
```

## 编译 GFC 包并进镜像

```bash
cd "$IMT_SRC"
export GFC_SRC="$GFC_REPO"
export GOFLAGS=-buildvcs=false

# 确保源码有 go.sum
cd "$GFC_SRC" && go mod tidy && cd "$IMT_SRC"

make package/gfc-client/compile V=s GFC_CLIENT_SRC="$GFC_SRC"
make package/luci-app-gfc/compile V=s

# 必须进 manifest
grep -i gfc bin/targets/x86/64/immortalwrt-x86-64-generic.manifest

# 若没有，强制重装 rootfs
rm -rf build_dir/target-x86_64_musl/root-*
make target/install -j"$(nproc)" V=s

grep -i gfc bin/targets/x86/64/immortalwrt-x86-64-generic.manifest
```

## 禁止操作

- **不要**在合并 `gfc-packages.config` 之后跑 `make defconfig`（会清掉 GFC 选包）
- **不要**只用 `package/gfc/` 软链而不跑 `setup-immortalwrt-feed.sh`

## 产物

- 固件：`bin/targets/x86/64/immortalwrt-x86-64-generic-ext4-combined-efi.img.gz`
- 清单：`bin/targets/x86/64/immortalwrt-x86-64-generic.manifest`（必须含 `gfc-client`）
