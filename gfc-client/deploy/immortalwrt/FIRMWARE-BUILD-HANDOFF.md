# GFC x86 固件构建 — 会话交接（FIRMWARE BUILD HANDOFF）

> 写给**完全没有本对话上下文**的新会话。  
> 最后更新：**2026-07-12**  
> 仓库：`sip-proxy` / `gfc-client/deploy/immortalwrt/`  
> 构建机：`/opt/gfc/{sip-proxy,immortalwrt}`（Ubuntu 22.04，用户 `gfcbuild`）

**权威构建步骤（简版）：** [`BUILD-FIRMWARE.md`](BUILD-FIRMWARE.md)  
**数据面/首启（未入库）：** 根目录 [`HANDOFF.md`](../../../HANDOFF.md) §P0 `image/99-gfc-firstboot`

---

## 1. 任务总览

| 主题 | 目标 |
|------|------|
| **GFC x86 OEM 固件** | ImmortalWrt 全量编译 → `combined-efi.img.gz`，刷盘即用 |
| **内置组件** | `gfc-client`、`luci-app-gfc`、LuCI、sing-box、unbound、nftables、dnsmasq-full、运维工具包 |
| **发布物** | ext4 EFI 镜像 + ipk +（可选）vmdk + `dist/gfc-os-v1/` |
| **验收** | `manifest` 含 gfc；刷机后 `opkg list-installed \| grep gfc`；`verify-dataplane-dns.sh` |

**产品方向：** 从「每台手动装 runtime tar」→「OEM 出厂镜像 + 线路码激活」。

---

## 2. 已完成（截至 2026-07-12）

### 2.1 构建机环境

| 项 | 状态 |
|----|------|
| ImmortalWrt 树 | ✅ `/opt/gfc/immortalwrt`（x86_64 generic） |
| `tools/install` + `toolchain/install` | ✅ 已成功（`gfcbuild` 用户） |
| Go 1.22.12 | ✅ `/usr/local/go`（**root 先装，需 `/etc/profile.d/go.sh` 给 gfcbuild**） |
| 首次全量 `make` | ✅ 产出 **无 GFC** 的 ImmortalWrt 镜像（42M img.gz） |

### 2.2 仓库已 push 的修复（`main`）

| Commit | 内容 |
|--------|------|
| `81947fd` | 去掉无效 `sqlite3-cli` DEPENDS；`GOARCH`/`GOFLAGS`；`setup-immortalwrt-feed.sh`；`gfc.env.example` |
| `54985d0` | `rebuild-gfc-image.sh`；setup 不再跑 `oldconfig` |
| `5bed56a` | feeds 路径强制、`package/gfc` 删除、rootfs opkg 回退装入 |

**关键文件：**

```
gfc-client/deploy/immortalwrt/
  scripts/setup-immortalwrt-feed.sh   # feeds src-link + 写 .config
  scripts/rebuild-gfc-image.sh        # 一键编镜像 + manifest 验收
  config/gfc-packages.config          # CONFIG_PACKAGE_gfc-*=y
  package/Makefile                    # PKG_RELEASE:=2，无 sqlite3-cli
  package/files/etc/gfc-client/gfc.env.example
  BUILD-FIRMWARE.md
```

### 2.3 已成功编出的产物

| 产物 | 路径 | 说明 |
|------|------|------|
| `gfc-client` ipk | `bin/packages/x86_64/base/gfc-client_1.1.0-r1_x86_64.ipk` | Go 三二进制已编进 ipk |
| `luci-app-gfc` ipk | `bin/targets/x86/64/packages/luci-app-gfc_*.ipk` | LuCI 集成 |
| ext4 镜像 | `bin/targets/x86/64/*ext4*combined*efi*.img.gz` | **曾有多版；仅 manifest 含 gfc 的才有效** |

### 2.4 已验证流程

- VMware：`.img` → `qemu-img convert` → `.vmdk` → UEFI 启动 ImmortalWrt ✅  
- 无 GFC 镜像可进 LuCI（仅默认菜单）✅  
- `feeds search` / `packageinfo` 可识别 `gfc-client`（去掉 sqlite3-cli 后）✅  

---

## 3. 当前卡在哪（P0 阻塞）

| 项 | 状态 | 说明 |
|----|------|------|
| **`manifest` 含 gfc-client** | ❌ **未通过** | 多次 `make` 后 `grep -i gfc *.manifest` 仍为空 |
| **`rebuild-gfc-image.sh` 完整跑通** | ❌ | 最后在 `ERROR: manifest has no gfc-client` 退出 |
| **含 GFC 的可刷机镜像** | ❌ | 现有 img/vmdk 为 **无 GFC** 版本，**应删除勿用** |
| **`image/99-gfc-firstboot`** | ❌ 未入库 | 刷盘后 fw4/DNS/门户需手工脚本或 overlay |
| **`go.sum` 入库** | ⚠️ | 构建机需 `go mod tidy`；仓库可能仍无 `go.sum` |
| **E2E 刷机 + 激活** | ❌ | 等 manifest 通过后再做 |

### 当前最可能根因（已部分修复，待验证）

1. GFC 包曾在 **`package/gfc/` 软链**，未走 **`package/feeds/gfc/`** → rootfs 未装入  
2. **`make oldconfig` / `syncconfig`** 曾删掉 `.config` 中的 GFC 行  
3. **rootfs 缓存** 未清空，manifest 反映旧 rootfs  
4. 最新脚本 `5bed56a` 应用 **feeds-only + opkg fallback**，**构建机需 `git pull` 后重跑**

---

## 4. 下一步计划（严格顺序）

### P0 — 产出含 GFC 的镜像（构建机）

```bash
export PATH=/usr/local/go/bin:$PATH
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export GOFLAGS=-buildvcs=false

cd /opt/gfc/sip-proxy && git pull
chown -R gfcbuild:gfcbuild /opt/gfc/sip-proxy /opt/gfc/immortalwrt   # 若曾用 root 编过

su - gfcbuild
chmod +x "$GFC_REPO/deploy/immortalwrt/scripts/"*.sh
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

**通过标准：**

```bash
grep -i gfc-client "$IMT_SRC/bin/targets/x86/64/immortalwrt-x86-64-generic.manifest"
find "$IMT_SRC/build_dir/target-x86_64_musl/root-"*/usr/bin/gfc-api
```

### P1 — 发布 + VMware

```bash
cp "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz /opt/gfc/dist/gfc-os-v1/
cd /opt/gfc/dist/gfc-os-v1 && gunzip -kf *.img.gz
qemu-img convert -f raw -O vmdk immortalwrt-x86-64-generic-ext4-combined-efi.img immortalwrt.vmdk
sha256sum * > SHA256SUMS
```

### P2 — 刷机验收

```bash
ssh root@192.168.1.1
opkg list-installed | grep gfc
/usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
# http://<LAN>/gfc/activate.html
```

### P3 — 入库首启 overlay（需用户「确认修改」）

- `image/files/etc/uci-defaults/99-gfc-firstboot`  
- 调用：`disable-immortalwrt-fw4.sh`、`configure-dnsmasq-dhcp.sh`、`install-luci-app.sh`  
- 软链：`ln -sfn .../image/files → $IMT_SRC/files` → 再 `make target/install`

### P4 — 日常 OTA

- 应用层：`pack-runtime.sh` → `upgrade-runtime.sh`（不必重刷整盘）  
- 大版本：新 `img.gz` → `sysupgrade -k`

---

## 5. 踩坑清单 — 新对话不要再踩

### 5.1 构建环境与用户

| 坑 | 正确做法 |
|----|----------|
| 在 **Windows** 上编 ImmortalWrt | 必须 **Ubuntu 构建机** 或 CI |
| **root** 与 **gfcbuild** 混用 | 统一 **gfcbuild**；`chown -R gfcbuild /opt/gfc/{sip-proxy,immortalwrt}` |
| root 编 tar 报 `FORCE_UNSAFE_CONFIGURE` | 用 gfcbuild，或 `export FORCE_UNSAFE_CONFIGURE=1` |
| Go 只给 root 装 PATH | `/etc/profile.d/go.sh` + `~gfcbuild/.bashrc` 加 `/usr/local/go/bin` |
| 不要用 **apt golang-go 1.18** | 用 **Go 1.22+** 官方 tarball |

### 5.2 `.config` 与 Kconfig

| 坑 | 正确做法 |
|----|----------|
| 写入 GFC 后跑 **`make defconfig`** | **禁止** — 会清掉 GFC 选包 |
| 写入 GFC 后跑 **`make oldconfig`** | 常 **删掉** GFC 行 — 用 `rebuild-gfc-image.sh` 或写入后 **直接 make** |
| 以为 **`packageinfo` 有包 = 进镜像** | 还要 **`.config` 有 `=y`** 且 **rootfs 装入** |
| 依赖 **`sqlite3-cli`**（不存在） | 已从 Makefile 移除；GFC 用 Go 内置 sqlite |
| 只用 **`package/gfc/` 软链** | 必须 **`feeds.conf` src-link** → `package/feeds/gfc/` |

### 5.3 编译 gfc-client

| 坑 | 正确做法 |
|----|----------|
| 无 **`go.sum`** | 构建机 `go mod tidy`（建议入库 `go.sum`） |
| **`GOARCH` 空** | Makefile 已用 `GFC_GOARCH`；或传 `GO_ARCH=amd64` |
| **VCS stamping** 失败 | `export GOFLAGS=-buildvcs=false` |
| 缺 **`gfc.env`** | `cp gfc.env.example gfc.env`（`gfc.env` 被 gitignore） |

### 5.4 产物与刷机

| 坑 | 正确做法 |
|----|----------|
| 在 **`bin/packages/`** 找 ipk | 也在 **`bin/targets/x86/64/packages/`** |
| **有 ipk 无 manifest** | 镜像 **无 GFC** — 以 **`grep gfc *.manifest`** 为准 |
| **`dist/gfc-os-v1` 与 `bin/targets` sha256 不同** | dist 可能是 **旧拷贝** — 以 **bin/targets 时间戳** 为准 |
| **`dd of=/dev/sdX` 字面执行** | 会创建 **`/dev/sdX` 普通文件** — 必须 **`lsblk` 确认真实盘** |
| 用 **squashfs** 镜像做 GFC 量产 | 用 **ext4 combined-efi** |
| 无 **`99-gfc-firstboot`** 就量产 | fw4/DNS 可能不对 — 见 P3 |

### 5.5 git 同步

| 坑 | 正确做法 |
|----|----------|
| root 下 `git pull` dubious ownership | `chown gfcbuild:sip-proxy` 或 `git -c safe.directory=... pull` |
| **`feeds search gfc`** 无输出 | 正常 — 本地/feed 包用 **`grep gfc-client tmp/.packageinfo`** |

---

## 6. 构建机目录与命令速查

```text
/opt/gfc/sip-proxy/              # 本仓库
/opt/gfc/immortalwrt/          # ImmortalWrt 源码树
/opt/gfc/dist/gfc-os-v1/       # 发布目录（手动 cp）
/opt/gfc/snapshots/            # 可选快照（staging_dir、.config）
```

```bash
# 一键（推荐）
bash /opt/gfc/sip-proxy/gfc-client/deploy/immortalwrt/scripts/rebuild-gfc-image.sh

# 验收三板斧
grep CONFIG_PACKAGE_gfc-client /opt/gfc/immortalwrt/.config
grep gfc-client /opt/gfc/immortalwrt/tmp/.packageinfo
grep -i gfc /opt/gfc/immortalwrt/bin/targets/x86/64/*.manifest
```

---

## 7. 相关 Git 提交（固件线）

```
5bed56a  fix: feeds path + opkg rootfs fallback
54985d0  fix: rebuild-gfc-image.sh, no oldconfig in setup
81947fd  fix: sqlite3-cli, feed setup, GOFLAGS, gfc.env.example
```

---

## 8. 给新对话的一句开场白

> 我们在做 **GFC x86 ImmortalWrt OEM 固件**。构建机 tools/toolchain 和 **gfc-client ipk 已编出**，但 **`manifest` 仍无 gfc-client**，含 GFC 的镜像 **尚未产出**。请先读 [`FIRMWARE-BUILD-HANDOFF.md`](FIRMWARE-BUILD-HANDOFF.md)，构建机 **`git pull`** 后跑 **`rebuild-gfc-image.sh`**，直到 **`grep gfc *.manifest`** 有输出。旧 img/vmdk **无 GFC 可删**。首启 overlay **`99-gfc-firstboot` 未入库**。改 package 前先读 [`.cursor/rules/gfc-firmware-build.mdc`](../../../.cursor/rules/gfc-firmware-build.mdc)。

---

*固件构建不修改 nft/unbound/sing-box 数据面契约；若改底层先读 `docs/*_ARCHITECTURE.md` 并出差异表。*
