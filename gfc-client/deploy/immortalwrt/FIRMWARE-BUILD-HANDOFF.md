# GFC x86 固件构建 — 会话交接（FIRMWARE BUILD HANDOFF）

> 写给**完全没有本对话上下文**的新会话。  
> 最后更新：**2026-07-21**（**r23**：r16 服务基线、dropbear/openssh、ORIG/rc.d、VGA；验证 **`437d990`**）  
> **本批详述：** [`docs/SESSION_HANDOFF_2026-07_FIRMWARE_BUILD_FIXES.md`](../../../docs/SESSION_HANDOFF_2026-07_FIRMWARE_BUILD_FIXES.md)  
> 仓库：`sip-proxy` / `gfc-client/deploy/immortalwrt/`  
> 构建机：`/opt/gfc/{sip-proxy,immortalwrt}`（Ubuntu 22.04，用户 `gfcbuild`）  
> Cursor 规则：[`gfc-firmware-build.mdc`](../../../.cursor/rules/gfc-firmware-build.mdc)（**alwaysApply**）、[`gfc-platform-ota-lifecycle.mdc`](../../../.cursor/rules/gfc-platform-ota-lifecycle.mdc)  
> 平台/OTA 交接：[`docs/SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md`](../../../docs/SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md)

**操作手册（命令/目录/模块）：** [`BUILD-FIRMWARE.md`](BUILD-FIRMWARE.md)  
**产品背景（旧）：** 根目录 [`HANDOFF.md`](../../../HANDOFF.md)（细节以本文 + BUILD-FIRMWARE 为准）

---

## 0. 新会话开场白（直接粘贴）

> 读 **`docs/SESSION_HANDOFF_2026-07_FIRMWARE_BUILD_FIXES.md`** 与 **`.cursor/rules/gfc-firmware-build.mdc`**。  
> GFC x86 OEM：**`gfc-client 1.1.0-r23`**；镜像 **`gfc-build-437d990-*ext4*combined*efi*.img.gz`**。  
> 构建：`export GFC_REPO=/opt/gfc/sip-proxy/gfc-client` 后 `rebuild-gfc-image.sh`；试编不 bump rN（§1.5）。  
> 激活：hard-retired → reclaim → **平台绑线路** → 再激活。

---

## 0.1 版本号澄清（r14 vs luci ~43402db）

| 信号 | 含义 |
|------|------|
| `luci-app-gfc - …~43402db` | LuCI 包编入了该 git 附近的前端/菜单 |
| `gfc-client - 1.1.0-r14` | **OpenWrt 包发布号**仍是 14（旧 Makefile）；**不能**反推 Go 二进制一定旧或一定新 |
| 正确做法 | bump `PKG_RELEASE` → 重建 → manifest 与 `opkg list-installed` 对齐；再用 API 探针验功能 |

详见 `docs/SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md` §4。

---

## 1. 本会话做了什么任务（2026-07-13）

| # | 任务 | 结果 |
|---|------|------|
| 1 | 刷盘后仍约 512MB | **r14**：按 OpenWrt wiki **两阶段**（95 扩分区重启 → 96 `resize2fs` 再重启）；持久日志 `/etc/gfc-client/expand-rootfs.log` |
| 2 | LAN 首次 DHCP 需手动 restart | **r14**：hotplug 覆盖 ifupdate；`gfc-lan-dhcp` START=99；firstboot 等 br-lan |
| 3 | `partx` / `parted` 包路径错误 | **已修**：`partx-utils`；`package/feeds/packages/parted` |

### 历史（2026-07-12 及更早）

| # | 任务 | 结果 |
|---|------|------|
| 1 | 修 `gfc-client` vs `luci-base` 争 `/www/index.html` | **r8**：ipk 不装 index；首启 `cp -f` |
| 2 | E2E：激活后无 `ip rule` | 根因 **`gfc-routing.sh` 无 +x** → Permission denied；**r9** chmod + `sh` 调用 |
| 3 | PC 需手动 `dnsmasq restart` 才拿 IP | **r9**：`hotplug.d/iface/99-gfc-dnsmasq` + firstboot 延迟 restart |
| 4 | 默认 root 密码 `Wgh@125434` | **r9/r10**：`97-gfc-oem-root-password`（`passwd` 回退，非仅 chpasswd） |
| 5 | 平台设备名 `(none)` | 控制面：占位主机名 → 线路 **TID**；heartbeat 不覆盖已改名 |
| 6 | 双 `fwmark→2022` rule | **r10**：循环清光再只加 `pref 100` |
| 7 | tc/HTB 限速缺模块 | **r10**：`tc-tiny` + `kmod-sched-core` + `kmod-ifb`；**禁止** 假包名 `kmod-sched-htb` |
| 8 | 创建线路时名称不进 TID | 控制面：`TID-{日期}-{名称}`；留空则随机 |
| 9 | WAN/LAN 口反了（stock lan=eth0 wan=eth1） | **r11**：首启探测，**WAN=首块、LAN=末块** |
| 10 | 刷机后仍无 `tc` | **r12**：merge 清 `# … is not set`；verify 强制 manifest/ORIG 有 tc；`apply-tc-htb` 认 `/usr/libexec/tc-tiny` |
| 11 | rebuild 在 merge 后静默退出 | **`set -e` + `grep -q && die`**：未匹配时函数返回 1 → 脚本中止；改为 `if grep` |

**相关提交（新→旧）：** r12 → `70d9ddf` → `6eb067a` → `fde1f00` → `1212375` → …

---

## 2. 已经完成了什么（累计）

### 2.1 构建机与管线

| 项 | 状态 |
|----|------|
| ImmortalWrt x86_64 + tools/toolchain | ✅ `/opt/gfc/immortalwrt`，用户 `gfcbuild` |
| Go 1.22+ | ✅ `/usr/local/go` + `GOFLAGS=-buildvcs=false` |
| Feed-only（无 legacy `package/gfc/`） | ✅ `package/feeds/gfc/` |
| `DEPENDS` 空 + `gfc-packages.config` | ✅ |
| manifest 含 gfc-client / luci-app-gfc | ✅（每次 rebuild 实测） |
| ORIG `root.orig-x86` 同步 | ✅ |
| 一键 `rebuild-gfc-image.sh` | ✅ |
| manifest / ORIG **强制**含 `tc-tiny` | ✅ **r12**（缺则 build fail） |
| manifest / ORIG **强制**含 `resize2fs` + expand 脚本 | ✅ **r13**（缺则 build fail） |

### 2.2 OEM 产品能力（源码侧，须刷对应 rN 镜像验证）

| 能力 | 版本 | 说明 |
|------|------|------|
| 首启 NAT + DNS hijack（未激活可上网） | r5+ | `99-gfc-firstboot` + `gfc-routing` |
| DHCP `force=1` + option 6 | r6+ | |
| Web 刷码 CGI（curl） | r6+ | |
| SSH dropbear **212** | r7+ | |
| gfctun hotplug → `ip rule` | r7+ / r9 修 +x | |
| 门户 index 不与 luci clash | r8+ | |
| deploy 脚本可执行 + lan DHCP hotplug | r9+ | |
| OEM root 密码 `Wgh@125434` | r10+（passwd） | |
| tc/HTB/ifb 进镜像 | r10 选包；**r12 强制验收** | HTB ∈ `kmod-sched-core`；二进制 `/usr/libexec/tc-tiny` |
| WAN=首块 / LAN=末块 | r11+ | `configure-network-ports.sh` |
| 首启自动扩 root | **r14** | `95` 扩分区重启 → `96` resize2fs；日志 `/etc/gfc-client/expand-rootfs.log` |
| LAN 首次 DHCP | **r14** | `gfc-lan-dhcp` + 强化 hotplug/firstboot |

### 2.3 设计结论（勿再争论）

1. 未激活：NAT + DNS hijack 先上；无 `gfctun` 时 **延迟** `ip rule` 是设计。  
2. 刷码 ≠ 立刻有策略路由；要等 agent + sing-box TUN + hotplug/post-start。  
3. `GFC_SSH_PORT` ≠ dropbear 端口；必须改 dropbear UCI。  
4. ImmortalWrt stock 常 **lan=eth0 / wan=eth1**；GFC OEM 改为 **wan=首块 / lan=末块**，并同步 `GFC_WAN_IFACE`。  
5. 固件工作 **不擅自改** nft/unbound/sing-box 架构契约。  
6. **OpenWrt `tc-tiny` 不把 `tc` 直接装进 PATH 文件树**：只装 `/usr/libexec/tc-tiny`，`/sbin/tc` 靠 **ALTERNATIVES**。验收要查 `tc-tiny` 包 **或** `/usr/libexec/tc-tiny`，不能只看 `which tc` 失败就断定「没编进镜像」——但 r12 起构建必须两者之一在 ORIG。  
7. **`resize2fs` 是独立 OpenWrt 包**（现场 `opkg install resize2fs`），**不在** `e2fsprogs` 内；镜像须 `CONFIG_PACKAGE_resize2fs=y`。  
8. **`partx` 二进制在包 `partx-utils`**；**没有** `CONFIG_PACKAGE_partx`（会让 package index 校验失败）。

---

## 3. 当前卡在哪

| 项 | 状态 |
|----|------|
| **r14 镜像重建 + 大盘扩容 + 首次 DHCP** | ⚠️ **当前卡点** |
| 控制面 TID / 设备名修复 | ⚠️ 须单独部署 control-plane + web-ui（非固件） |
| P1 dist/vmdk 发布打包 | ❌ 可选未做 |

**一句话：** 源码已到 r13（强制 tc + 首启扩盘）；**下一优先：构建机编出 r13 → 刷大于镜像的盘，验收 `df -h /` 与 tc。**

---

## 4. 下一步（严格顺序）

### P0 — 重建并刷 r14

见 [`BUILD-FIRMWARE.md`](BUILD-FIRMWARE.md) §3–§5。期望 manifest：`gfc-client - 1.1.0-r14`。刷大盘后允许自动重启 1～2 次再查 `df -h /`。

### P1 — E2E 清单（刷机后）

| # | 检查 | 期望 |
|---|------|------|
| 1 | `opkg list-installed \| grep gfc-client` | `1.1.0-r14` |
| 11 | 扩容 | 等自动重启结束；`df -h /` ≈ 盘；`cat /etc/gfc-client/expand-rootfs.log`；存在 `rootpt-resized`+`rootfs-resized` |
| 12 | DHCP | PC 插 LAN 应自动拿 IP；`cat /tmp/gfc-dnsmasq-hotplug.log` |
| 2 | `uci get network.wan.device` | 首块（如 `eth0`） |
| 3 | `br-lan` ports | 末块（如 `eth1`） |
| 4 | LAN DHCP | 无需手动 restart dnsmasq |
| 5 | `uci get dhcp.@dnsmasq[0].force` | `1` |
| 6 | `nft list tables` | `nat` / `gfc_dns_hijack` / `gfc` |
| 7 | Web 激活 | 无 `flash request failed` |
| 8 | 激活后 | `gfctun` 存在；**仅一条** `fwmark 0x2023 lookup 2022` |
| 9 | SSH | 端口 **212**；密码 **`Wgh@125434`** |
| 10 | tc | `opkg list-installed \| grep tc-tiny`；`ls -l /sbin/tc /usr/libexec/tc-tiny`；`command -v tc` 或直接跑 libexec |
| 11 | 扩容 | `df -h /` ≈ 物理盘；`cat /tmp/gfc-expand-rootfs.log`；`opkg list-installed \| grep -E 'resize2fs|parted|partx-utils'` |

### P2 — 可选发布

拷贝最新 `*ext4*combined*efi*.img.gz` → `/opt/gfc/dist/gfc-os-v1/`，可选 vmdk + sha256。

---

## 5. 踩坑清单 — 新对话不要再踩

### 5.1 构建环境

| 坑 | 正确做法 |
|----|----------|
| Windows 编 ImmortalWrt | 必须 Ubuntu 构建机 |
| root / gfcbuild 混用 | 统一 **gfcbuild**；`chown -R` |
| apt golang 1.18 | `/usr/local/go` **1.22+** |
| 无 `GOFLAGS=-buildvcs=false` | 必设 |
| 构建机未 `git pull` | 先 pull 再 rebuild |

### 5.2 Feed / Kconfig / 选包

| 坑 | 正确做法 |
|----|----------|
| legacy `package/gfc/` | 只用 `package/feeds/gfc/` |
| `feeds update gfc` / `feeds install -a` | `feeds update -i gfc` + `feeds install -f …` |
| 非空 `DEPENDS` | **必须空** |
| `CONFIG_PACKAGE_nftables` | **`nftables-json`** + `kmod-nft-core` |
| `CONFIG_PACKAGE_kmod-sched-htb` | **无此包**；用 **`kmod-sched-core`**（含 sch_htb）+ `tc-tiny` + `kmod-ifb` |
| 合并后 `defconfig` / `oldconfig` | **禁止** |
| merge 只删 `CONFIG_*=` 留 `# … is not set` | **r12** 同时 scrub；verify 硬失败 |
| `verify_dotconfig` 用 `grep -q && die` | **`set -e` 下未匹配会静默退出**；必须用 `if grep; then die; fi` |
| 只验 gfc、不验 tc | **r12** manifest/ORIG 必须有 tc-tiny |
| 只选 `e2fsprogs` 期望有 `resize2fs` | **错**；须 **`CONFIG_PACKAGE_resize2fs=y`**（独立包） |
| `CONFIG_PACKAGE_partx=y` | **错**；包名是 **`partx-utils`** |
| `make package/utils/parted/compile` | **错**；`parted` 在 **packages feed**：`package/feeds/packages/parted` |
| `opkg install ip-full` 当 tc 回退 | **错**；ip-full 不含 tc |

### 5.3 rootfs / 镜像 / 打包

| 坑 | 正确做法 |
|----|----------|
| 只查 `root-x86` | 同步并验收 **`root.orig-x86`** |
| ipk 装 `/www/index.html` | **禁止**（luci-base clash） |
| deploy `*.sh` 0644 | install **`chmod 0755`**；调用用 **`sh script`** |
| 以 ipk 当成功 | 唯一标准：**manifest 含 gfc-client**（+ r12 起含 tc-tiny） |
| 删 root 后只 `target/install` | 先 **`package/install`** |
| opkg arch `x86` | 必须 **`x86_64`** |
| 只 `command -v tc` | 另查 `/usr/libexec/tc-tiny`（ALTERNATIVES） |

### 5.4 首启 / 现场

| 坑 | 正确做法 |
|----|----------|
| 指望 postinst 在编镜像时跑 | 必须 **uci-defaults** |
| `chpasswd` 设密码失败 | OpenWrt 常无 chpasswd → 用 **`passwd`** |
| 刷码后立刻无 `ip rule` | 查 **gfctun**、脚本 **+x**、hotplug 日志 |
| `ip rule` 出现两条 2022 | r10 前 start 重复 add；应清光再加一条 |
| stock lan=eth0 / wan=eth1 | r11 起首启纠正；查 `configure-network-ports` |
| 只改 `GFC_SSH_PORT` | 改 **dropbear Port=212** |

### 5.5 架构边界

| 坑 | 正确做法 |
|----|----------|
| 改 nft 表名/mark/hook「图方便」 | **禁止** |
| MosDNS / sing-box DNS 替 unbound 服务 LAN | **禁止** |
| kernel-split `auto_route` | **禁止** |
| `docs/draft/*` 覆盖正式架构文档 | draft 非正式真相 |

---

## 6. 关键路径速查

```text
gfc-client/deploy/immortalwrt/
  BUILD-FIRMWARE.md                     # 操作手册
  FIRMWARE-BUILD-HANDOFF.md             # 本文件（状态/卡点/踩坑）
  scripts/rebuild-gfc-image.sh          # 一键编镜像（r12 强制验 tc）
  scripts/setup-immortalwrt-feed.sh     # feed v4
  scripts/ensure-gfc-package-index.sh   # 包索引校验
  config/gfc-packages.config            # 选包（勿 defconfig）
  config/gfc-package-index.txt          # 索引清单
  package/Makefile                      # PKG 1.1.0-r12；DEPENDS 空
  package/files/etc/uci-defaults/
    95-gfc-rootpt-resize
    96-gfc-rootfs-resize
    97-gfc-oem-root-password
    98-gfc-network-ports
    99-gfc-firstboot
  package/files/etc/init.d/
    gfc-lan-dhcp
    …
  package/files/etc/hotplug.d/
    net/99-gfc-tun
    iface/99-gfc-dnsmasq
  configure-network-ports.sh            # WAN=首 / LAN=末
  configure-dnsmasq-dhcp.sh
  configure-dropbear-ssh.sh
  gfc-routing.sh
  www/…                                 # 激活门户（index 不进 ipk 的 /www）
gfc-client/deploy/apply-tc-htb.sh       # 限速（认 /usr/libexec/tc-tiny）
```

---

## 7. 关键 Git 提交（固件线，新→旧）

```
(r12)    fix: force tc-tiny into image; ALTERNATIVES-aware apply-tc-htb
70d9ddf  feat: WAN=first / LAN=last NIC (r11)
6eb067a  fix: scrub stale kmod-sched-htb from .config
fde1f00  fix: drop invalid kmod-sched-htb; HTB in kmod-sched-core
1212375  fix: r10 ip-rule dedupe, root passwd, tc/htb; TID uses name
98a5cd0  fix: r9 routing +x, DHCP hotplug, password, device name TID
0837ab6  fix: omit /www/index.html from ipk (r8)
b28f0f3  fix: policy route hotplug; SSH dropbear :212 (r7)
b5f770e  fix: OEM firstboot DHCP/NAT and web flash CGI (r6)
7bb5583  feat: OEM 99-gfc-firstboot (r5)
…
```

---

## 8. 现网临时救火（不持久）

```sh
# 网卡口（≥2 NIC）
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-network-ports.sh
# SSH 212
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-dropbear-ssh.sh
# 密码
printf '%s\n%s\n' 'Wgh@125434' 'Wgh@125434' | passwd root
# 策略路由（须先有 gfctun；脚本用 sh）
GFC_ROUTING_TUN_WAIT=5 sh /usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh start
# tc（若仅缺 symlink）
[ -x /usr/libexec/tc-tiny ] && ln -sf /usr/libexec/tc-tiny /sbin/tc
```

---

*固件构建不修改 nft/unbound/sing-box 数据面契约；改底层先读 `docs/*_ARCHITECTURE.md` 并出差异表，等用户「确认修改」。*
