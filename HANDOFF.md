# GFC 会话交接（HANDOFF）

> 写给**完全没有上下文**的新对话。  
> 最后更新：**2026-07-10**（GFC x86 专用固件 OEM 化方案 + 既有 ImmortalWrt 客户端运维背景）。  
> 仓库：`sip-proxy`（`gfc-platform/` 控制平台 + `gfc-client/` ImmortalWrt 客户端）。

**说明：** `main` 上可能还有与本文并行的工作（远程运维、路由模式拆分、RBAC 等）。若任务与「固件构建」无关，见本文 **§8 历史背景**；若涉及 unbound/nft/sing-box 底层，必须先读架构文档出差异表。

---

## 1. 本会话在做什么（任务总览）

| 主题 | 目标 |
|------|------|
| **GFC 盒子可移植化** | 将已部署的 ImmortalWrt x86 GFC 终端做成可批量刷写的专用固件 |
| **第一版：刷盘即用** | 一次构建 `combined-efi.img.gz`，多台 x86 工控机/软路由批量 `dd` 刷入 |
| **后续迭代：升级包** | 日常发版用 **runtime tarball** 在已刷固件上升级；大版本用 **sysupgrade** |
| **镜像内置运维工具** | 构建时预装 `curl`、`wget-ssl`、`tcpdump`、`iftop`、`bmon` 等 |
| **（背景）现场 runtime 稳定性** | 前序会话已修 LAN 下联、fw4 冲突、unbound bootstrap；固件首启必须复用同一套脚本 |

**产品方向：** 从「每台手动装 ImmortalWrt + runtime tar」升级为「OEM 出厂镜像 + 线路码激活」。

---

## 2. 已经完成了什么

### 2.1 本会话 — 方案与设计（文档级，**未入库代码**）

| 项 | 状态 | 说明 |
|----|------|------|
| 三条移植路径对比 | ✅ 已分析 | A 磁盘克隆 / B runtime 批量部署 / C 定制 ImmortalWrt 固件 |
| **选定主路径** | ✅ | **C：ImmortalWrt 全量编译 + GFC feed + `files/` overlay** |
| 构建机环境清单 | ✅ | Ubuntu 22.04、依赖包、`/opt/gfc/{sip-proxy,immortalwrt}` 目录规划 |
| Feed 接入方式 | ✅ | 软链 `package/gfc/gfc-client`、`package/gfc/luci-app-gfc` |
| 首启关键缺口定位 | ✅ | `gfc-client` 的 `postinst` 在镜像构建时因 `IPKG_INSTROOT` **不执行** → 必须 `uci-defaults` |
| 首启脚本设计草案 | ✅ | `99-gfc-firstboot`：LuCI 门户、关 fw4、dnsmasq port=0、unbound、bootstrap、gfc-routing |
| `.config` 包列表示例 | ✅ | `gfc-client`、`luci-app-gfc`、`sing-box`、`unbound`、`nftables`、kmod-tun 等 |
| 运维工具装入方式 | ✅ | `.config` 加 `CONFIG_PACKAGE_<pkg>=y` 或维护 `image/packages.txt` |
| 升级双通道 | ✅ | **通道 A** `pack-runtime.sh` → `upgrade-runtime.sh`；**通道 B** `sysupgrade -k` |
| 发版清单模板 | ✅ | `BUILDINFO.txt`、SHA256、commit 记录 |

### 2.2 仓库已有、可直接用于固件化的资产

| 路径 | 用途 |
|------|------|
| `gfc-client/deploy/immortalwrt/package/Makefile` | OpenWrt `.ipk` 配方；`DEPENDS` 已含 sing-box、unbound、nftables、autossh 等 |
| `gfc-client/deploy/immortalwrt/luci-app-gfc/` | LuCI 管理界面（**未**打进 `gfc-client` ipk，需单独选包或首启安装） |
| `gfc-client/deploy/immortalwrt/pack-runtime.sh` | 打 `gfc-immortalwrt-runtime-amd64-*.tar.gz`（**日常升级包**） |
| `gfc-client/deploy/immortalwrt/upgrade-runtime.sh` | 设备上原地升级（保留 `/var/lib/gfc-client` 激活状态） |
| `gfc-client/deploy/immortalwrt/install-runtime.sh` | 首次手动安装逻辑（首启 uci-defaults 应调用同等步骤） |
| `gfc-client/deploy/immortalwrt/install-luci-app.sh` | 激活门户 + LuCI 菜单 |
| `gfc-client/deploy/immortalwrt/disable-immortalwrt-fw4.sh` | ★ 必须关 stock fw4 |
| `gfc-client/deploy/immortalwrt/configure-dnsmasq-dhcp.sh` | ★ dnsmasq `port=0` + DHCP option 6 |
| `gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh` | ★ 刷机/升级后验收 |
| `gfc-client/deploy/immortalwrt/luci-app-gfc/root/etc/uci-defaults/99-gfc-portal` | 门户首启（仅 LuCI 部分，不够覆盖数据面） |

### 2.3 前序会话已完成的客户端稳定性（与固件首启强相关）

| 项 | 状态 | 说明 |
|----|------|------|
| fw4 与 GFC nft 冲突 | ✅ | `disable-immortalwrt-fw4.sh`（`3f5a379`） |
| unbound bootstrap / trust anchor | ✅ | 不 patch `/etc/unbound/root.key`；`chroot: ""`（`4325b3d`） |
| 无 sing-box.json 也启 gfc-routing | ✅ | 激活前也应有 NAT + DNS hijack（`9416ce9`） |
| WAN apply 安全 / 回滚 | ✅ | `gfc-bootstrap --rollback-network`（`454a873`） |
| 下联验收脚本 | ✅ | `verify-dataplane-dns.sh` |

---

## 3. 当前卡在哪 / 未闭环项

| 项 | 状态 | 说明 |
|----|------|------|
| **固件构建资产入库** | ❌ 未做 | 无 `gfc-client/deploy/immortalwrt/image/`（`files/`、`packages.txt`、`build-gfc-image.sh`、`README.md`） |
| **首启 uci-defaults 入库** | ✅ | `99-gfc-firstboot` 在 `image/files` + `gfc-client` ipk（`PKG_RELEASE:=5`） |
| **第一台 OEM 镜像编译** | ✅ | manifest 含 `gfc-client`；ext4-combined-efi.img.gz |
| **刷机 + 首启 + 激活 E2E** | ❌ 未做 | 需重建含 firstboot 的镜像后刷机验收 |
| **现场 runtime 对齐** | ⚠️ 可能仍滞后 | 已部署设备可能还在用手动装 runtime；固件化不替代已有设备的 runtime 升级 |
| **Windows 开发机** | ℹ️ | 无 `go`；固件编译需在 **Linux 构建机**，Go 测试同理 |

### 仓库 git 状态（本会话结束时）

- 未提交固件相关新文件；`docs/draft/` 下可能有架构草案（与正式 `docs/*_ARCHITECTURE.md` 区分）。

---

## 4. 下一步计划（建议顺序）

### P0 — 固件资产入库（需用户「确认修改」）

在 `gfc-client/deploy/immortalwrt/image/` 新增：

```
image/
├── README.md                    # 构建/刷机/升级全文
├── packages.txt                 # 运维工具：curl wget-ssl tcpdump iftop bmon ...
├── files/etc/uci-defaults/
│   └── 99-gfc-firstboot         # 首启编排（调现有 deploy 脚本）
└── build-gfc-image.sh           # 链 feeds、写 .config、make
```

`build-gfc-image.sh` 核心逻辑：

```sh
# 软链 GFC 包 → package/gfc/
# ln -sfn image/files → $IMT_SRC/files
# 写入 GFC 核心 CONFIG_PACKAGE_*=y
# while read pkg; do echo CONFIG_PACKAGE_${pkg}=y; done < packages.txt
# make download && make -j$(nproc) V=s
```

### P1 — 构建机首次全量编译

```sh
export GFC_SRC=/opt/gfc/sip-proxy
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_VERSION=v1.0.0

# 克隆 ImmortalWrt（锁定分支）→ feeds update/install
# 运行 build-gfc-image.sh 或按 image/README.md 手工步骤
# 产物：bin/targets/x86/64/*-combined-efi.img.gz
```

### P2 — 刷机与首启验收

```sh
# PC 上 gunzip + dd 到目标盘
# 首启 SSH：
grep GFC_IMAGE_VERSION /etc/gfc-client/gfc.env
/usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
# 浏览器：http://<LAN-IP>/gfc/activate.html
```

### P3 — 发 v1.0.1（应用层升级，不重刷整盘）

```sh
cd gfc-client
GOARCH=amd64 bash deploy/immortalwrt/pack-runtime.sh
# 设备：tar xzf && ./install.sh  → 走 upgrade-runtime.sh
```

### P4 — 大版本底包升级（按需）

```sh
# 设备上
sysupgrade -k /tmp/immortalwrt-*-combined-efi.img.gz
```

### P5 — 已有手动部署设备

继续用 runtime tar 升级，**不必**等固件完成；固件主要服务**新出厂**硬件。

---

## 5. 踩过的坑 — 新对话不要再踩

### 5.1 固件构建 / OEM 化（本会话）

| 坑 | 正确做法 |
|----|----------|
| 以为 `gfc-client` 的 `postinst` 会在镜像里跑 | 构建阶段 `IPKG_INSTROOT` 非空 → **postinst 直接 exit 0**；首启必须用 **`/etc/uci-defaults/`** |
| 只打 `gfc-client` ipk、不选 `luci-app-gfc` | 设备无 GFC LuCI 菜单；须单独选包或首启 `install-luci-app.sh` |
| 用 runtime tar 思路做「整盘镜像」 | runtime **不含 sing-box 二进制**（ipk DEPENDS 会装）；整盘镜像靠 **ImmortalWrt 编译选包** |
| 出厂镜像预置激活状态 | 克隆多台会 **device_id 冲突**；出厂镜像应保持未激活，每台单独 flash 线路码 |
| 把 `curl`/`iftop` 写进 `gfc-client` DEPENDS | 运维工具应进 **`packages.txt` / `.config`**，与业务包解耦 |
| Ubuntu 的 `wget` 包名照抄 | OpenWrt 用 **`wget-ssl`**；busybox 自带 wget 功能弱 |
| 找不到 `iftop`/`bmon` | 先 `./scripts/feeds search <name>`；`feeds update -a` 后再 menuconfig |
| 磁盘克隆当长期 OTA 方案 | 克隆适合同型号急救；量产应 **定制固件 + runtime 升级包** |
| 首启未关 fw4 / 未配 dnsmasq | 下联 PC 不能上网；首启必须调 **`disable-immortalwrt-fw4.sh`** + **`configure-dnsmasq-dhcp.sh`** |
| 假设 WAN 一定是 `eth0` | 写入 `/etc/gfc-client/gfc.env` 的 `GFC_WAN_IFACE`；不同硬件首启后可能要改 |

### 5.2 DNS / unbound / 下联 PC（前序会话，固件首启同样适用）

| 坑 | 正确做法 |
|----|----------|
| patch `auto-trust-anchor` 到 `/etc/unbound/root.key` | ImmortalWrt checkconf **fatal**；保持 `/var/lib/unbound/root.key` + `chroot: ""` |
| unbound snippet 未部署 | bootstrap 失败 → **:53 无服务** |
| dnsmasq 未 `port=0` 或无 DHCP option 6 | 下联 PC **无 DNS** |
| 无 `sing-box.json` 就不启 `gfc-routing` | **必须先启 gfc-routing**（NAT + hijack），激活前也要能上网 |

### 5.3 nft / fw4

| 坑 | 正确做法 |
|----|----------|
| ImmortalWrt **fw4 默认开启** | 与 `inet gfc` / `inet nat` / `gfc_dns_hijack` **冲突**；必须 `disable-immortalwrt-fw4.sh` |
| `apply-network` restart firewall | 会拉起 fw4 → 已改为 stop+disable |

### 5.4 WAN / apply-network

| 坑 | 正确做法 |
|----|----------|
| 无 `network-wan.json` 时默认写 `proto=dhcp` | **先从 UCI seed**；见 `NETWORK_APPLY.md` |
| LuCI「回滚配置」恢复 WAN | **不能**；用 `gfc-bootstrap --rollback-network` |

### 5.5 开发与流程

| 坑 | 正确做法 |
|----|----------|
| 未读架构文档就改 unbound/nft/sing-box | 违反 `.cursor/rules/*-no-change-without-approval.mdc` |
| 改底层未跑验收 | 必须 **`verify-dataplane-dns.sh`** |
| 在 Windows 上编 ImmortalWrt / 跑 `go test` | 用 Linux 构建机或 CI |

---

## 6. 固件构建速查（新会话可直接用）

### 6.1 构建机准备

```sh
sudo apt install -y build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses5-dev libssl-dev python3 python3-distutils \
  python3-setuptools rsync unzip zlib1g-dev file wget curl golang-go
```

### 6.2 接入 GFC 包

```sh
cd /opt/gfc/immortalwrt
mkdir -p package/gfc
ln -sfn /opt/gfc/sip-proxy/gfc-client/deploy/immortalwrt/package package/gfc/gfc-client
ln -sfn /opt/gfc/sip-proxy/gfc-client/deploy/immortalwrt/luci-app-gfc package/gfc/luci-app-gfc
./scripts/feeds update -a && ./scripts/feeds install -a
```

### 6.3 overlay（首启）

```sh
# 目标：image/files → immortalwrt/files（构建时软链）
ln -sfn /opt/gfc/sip-proxy/gfc-client/deploy/immortalwrt/image/files /opt/gfc/immortalwrt/files
```

### 6.4 核心 `.config` 片段

```sh
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
CONFIG_TARGET_ROOTFS_PARTSIZE=512

CONFIG_PACKAGE_gfc-client=y
CONFIG_PACKAGE_luci-app-gfc=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_unbound-daemon=y
CONFIG_PACKAGE_unbound-checkconf=y
CONFIG_PACKAGE_nftables=y
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_libcap-bin=y
CONFIG_PACKAGE_kmod-tun=y

# 运维工具（示例）
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_wget-ssl=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_iftop=y
CONFIG_PACKAGE_bmon=y
```

### 6.5 编译与产物

```sh
make defconfig
make download -j$(nproc) V=s
make package/gfc-client/compile V=s GFC_CLIENT_SRC=/opt/gfc/sip-proxy/gfc-client
make -j$(nproc) V=s
ls -lh bin/targets/x86/64/*combined*efi*.img.gz
```

### 6.6 升级包（不重刷整盘）

```sh
cd /opt/gfc/sip-proxy/gfc-client
GOARCH=amd64 bash deploy/immortalwrt/pack-runtime.sh
# 设备：tar xzf && cd gfc-immortalwrt-runtime-* && ./install.sh
```

---

## 7. 权威文档与 Cursor 规则

| 领域 | 权威 `.md` | AI 变更协议 `.mdc` |
|------|------------|---------------------|
| nft | `docs/NFT_ARCHITECTURE.md` | `nft-no-change-without-approval.mdc` |
| DNS/unbound | `docs/UNBOUND_ARCHITECTURE.md` | `unbound-no-change-without-approval.mdc` |
| sing-box | `docs/SINGBOX_ARCHITECTURE.md` | `singbox-no-change-without-approval.mdc` |
| WAN apply | `gfc-client/docs/NETWORK_APPLY.md` | `network-apply-no-change-without-approval.mdc` |
| 数据面/验收 | `gfc-client/docs/DATAPLANE_CHANGE.md` | `dataplane-bottom-layer.mdc` |
| ImmortalWrt 适配 | `gfc-client/deploy/immortalwrt/README.md` | — |
| 远程运维 | `gfc-platform/docs/REMOTE_ACCESS.md` | — |

**固件任务固定口令：**

> 严格按既有架构文档，只改我点名的 `image/` 或 `package/` 文件，改前先给差异表，确认后再写代码；刷机后跑 `verify-dataplane-dns.sh`。

---

## 8. 历史背景（非本会话主任务，但新对话可能碰到）

### 8.1 远程运维（`gfc-platform/`）

- 控制面反向 SSH + WebSSH + LuCI 反代；`gfc-reverse-ssh` **平时 disabled 正常**
- 见 `gfc-platform/docs/REMOTE_ACCESS.md`；tag `gfc-remote-ssh-web-v1.0.0`

### 8.2 关键 Git 提交（数据面稳定性）

```
454a873  fix: safe apply-network WAN + xterm WebSSH
adf9125  fix(client): OpenWrt PPPoE WAN apply
4325b3d  fix(client): unbound root.key ImmortalWrt bootstrap
9416ce9  fix(client): LAN DNS/NAT after upgrade gaps + verify script
3f5a379  fix(client): disable ImmortalWrt fw4
302bd64  docs: network rollback disables fw4
```

### 8.3 LAN 数据路径（验收心智模型）

```
下联 PC
  → DHCP option 6 = 网关 LAN IP
  → DNS → 网关:53 → gfc-unbound
  → nft gfc_dns_hijack
  → nft nat masquerade（gfc-routing；fw4 必须 disabled）
  → 国内 TO_CN 直连 / 国际 mark → gfctun → sing-box（已激活时）
```

---

## 9. 关键文件索引

```
gfc-client/deploy/immortalwrt/
  package/Makefile              # .ipk 配方（固件选包用）
  luci-app-gfc/                 # LuCI（须单独选包）
  pack-runtime.sh               # ★ 日常升级包
  upgrade-runtime.sh            # ★ 设备原地升级
  install-runtime.sh            # 首启逻辑参考
  install-luci-app.sh
  disable-immortalwrt-fw4.sh      # ★ 首启必调
  configure-dnsmasq-dhcp.sh     # ★ 首启必调
  ensure-unbound-dirs.sh
  verify-dataplane-dns.sh       # ★ 刷机/升级验收
  gfc-routing.sh
  README.md                     # 现有 SDK/runtime 文档（非 OEM 镜像）

# 待建（P0）：
  image/
    README.md
    packages.txt
    files/etc/uci-defaults/99-gfc-firstboot
    build-gfc-image.sh
```

---

## 10. 给新对话的一句开场白

> 我们在规划 **GFC x86 刷盘即用 OEM 固件**：用 ImmortalWrt 全量编译 + `gfc-client`/`luci-app-gfc` feed + `files/etc/uci-defaults` 首启（因 ipk postinst 在镜像构建时不执行）。**方案与会话文档已写好，但 `image/` 目录尚未入库**。请帮用户落地 P0（`packages.txt`、`99-gfc-firstboot`、`build-gfc-image.sh`），锁定 ImmortalWrt 分支后编出 `combined-efi.img.gz` 并跑 `verify-dataplane-dns.sh`。日常发版用 `pack-runtime.sh` 升级包，不必重刷整盘。改底层前读 `DATAPLANE_CHANGE.md` 出差异表；首启必须关 fw4、dnsmasq port=0。

---

*若本文与 `docs/NFT_ARCHITECTURE.md`、`docs/UNBOUND_ARCHITECTURE.md`、`docs/SINGBOX_ARCHITECTURE.md` 冲突，以权威架构文档为准。*
