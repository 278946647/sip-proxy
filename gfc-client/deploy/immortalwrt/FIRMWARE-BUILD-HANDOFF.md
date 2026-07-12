# GFC x86 固件构建 — 会话交接（FIRMWARE BUILD HANDOFF）

> 写给**完全没有本对话上下文**的新会话。  
> 最后更新：**2026-07-12**（会话压缩后记忆固化；`main` @ `b28f0f3`）  
> 仓库：`sip-proxy` / `gfc-client/deploy/immortalwrt/`  
> 构建机：`/opt/gfc/{sip-proxy,immortalwrt}`（Ubuntu 22.04，用户 `gfcbuild`）  
> Cursor 规则：[`gfc-firmware-build.mdc`](../../../.cursor/rules/gfc-firmware-build.mdc)

**权威操作步骤（简版）：** [`BUILD-FIRMWARE.md`](BUILD-FIRMWARE.md)  
**产品/首启总览：** 根目录 [`HANDOFF.md`](../../../HANDOFF.md)（旧；以本文 §2–§4 为准）

---

## 0. 新会话开场白（直接粘贴）

> 我们在做 **GFC x86 ImmortalWrt OEM 固件**。构建管线已能产出 **manifest 含 `gfc-client`** 的镜像；首启/刷码/SSH/策略路由源码已修到 `PKG_RELEASE:=7`（`b28f0f3`）。**当前卡在：用含 r7 的镜像重建并刷机做 E2E 验收**（DHCP、NAT、Web 激活、SSH 212、`ip rule`）。请先读 `gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md`，严格按 `.cursor/rules/gfc-firmware-build.mdc`。构建机 `git pull` 后跑 `rebuild-gfc-image.sh`，刷最新 `*ext4*combined*efi*.img.gz`。

---

## 1. 任务总览（我们在做什么）

| 主题 | 目标 |
|------|------|
| **GFC OS / OEM 固件** | ImmortalWrt 全量编译 → `combined-efi.img.gz`，刷盘即用 |
| **内置组件** | `gfc-client`、`luci-app-gfc`、LuCI、sing-box、unbound、nftables-json、dnsmasq-full、运维工具 |
| **产品形态** | 未激活也能 **DHCP + NAT + DNS 劫持**；激活后才开代理（`sing-box` / `gfctun`） |
| **发布物** | ext4 EFI 镜像 + ipk +（可选）vmdk + `dist/gfc-os-v1/` |
| **验收** | manifest 含 gfc；刷机后 DHCP/NAT/Web 刷码；激活后 `ip rule`；SSH **212** |

**产品方向：** 「每台手动装 runtime tar」→「OEM 出厂镜像 + 线路码激活」。

---

## 2. 已经完成了什么

### 2.1 构建机环境

| 项 | 状态 |
|----|------|
| ImmortalWrt 树 | ✅ `/opt/gfc/immortalwrt`（x86_64 generic） |
| tools / toolchain | ✅ `gfcbuild` 用户 |
| Go 1.22+ | ✅ `/usr/local/go`（需 `PATH` / profile） |
| 一键脚本 | ✅ `scripts/rebuild-gfc-image.sh` + `setup-immortalwrt-feed.sh` **v4** |

### 2.2 构建管线（P0 构建成功标准已达成过）

| 项 | 状态 | 说明 |
|----|------|------|
| Feed 仅 `package/feeds/gfc/` | ✅ | 禁止 legacy `package/gfc/` |
| `gfc-client` Kconfig 注册 | ✅ | **`DEPENDS` 必须为空**；运行时包走 `gfc-packages.config` |
| ipk 产出 | ✅ | `gfc-client_1.1.0-r*_x86_64.ipk` |
| **manifest 含 gfc-client** | ✅ | 曾通过；以每次 rebuild 实测为准 |
| **ORIG rootfs 同步** | ✅ | 镜像读 `root.orig-x86`，不只 `root-x86` |
| 选包 fragment | ✅ | `config/gfc-packages.config`（`nftables-json` 等） |

### 2.3 OEM 首启与运行时修复（源码已 push）

| Commit | PKG | 内容 |
|--------|-----|------|
| `7bb5583` | r5 | `99-gfc-firstboot`（`image/files` + package） |
| `b5f770e` | r6 | DHCP **`force=1`**；CGI 优先 **curl**；未激活缩短 TUN 等待；www 进 ipk |
| `b28f0f3` | **r7** | **dropbear Port 212**；**`99-gfc-tun` hotplug**；sing-box 后轮询再跑 routing |

### 2.4 设计结论（勿再争论）

1. **未激活也要通网：** firstboot / `gfc-routing` 先装 NAT + DNS hijack；`gfctun` 未出现时 **延迟** `ip rule`，不算「routing 失败」。
2. **刷码 ≠ 策略路由立刻齐全：** flash 只到 `pending_activate`；`fwmark 0x2023 → table 2022` 要等 **agent 激活 + sing-box 起 TUN**（hotplug / post-start 补装）。
3. **`GFC_SSH_PORT=212` ≠ dropbear 已改：** 以前只影响 nft bypass；r7 起 firstboot 调 `configure-dropbear-ssh.sh`。
4. **数据面契约不变：** 固件工作不擅自改 nft/unbound/sing-box 架构；见 `docs/*_ARCHITECTURE.md` + 对应 no-change 规则。

### 2.5 关键路径速查

```text
gfc-client/deploy/immortalwrt/
  scripts/rebuild-gfc-image.sh          # 一键编镜像 + ORIG 同步 + manifest 验收
  scripts/setup-immortalwrt-feed.sh     # v4: feeds update -i + install -f
  scripts/ensure-gfc-package-index.sh   # 运行时包进 packageinfo
  config/gfc-packages.config            # CONFIG_PACKAGE_*=y（勿 defconfig/oldconfig）
  package/Makefile                      # PKG_VERSION=1.1.0 PKG_RELEASE=7；DEPENDS 空
  package/files/etc/uci-defaults/99-gfc-firstboot
  package/files/etc/hotplug.d/net/99-gfc-tun
  image/files/etc/uci-defaults/99-gfc-firstboot   # overlay → $IMT_SRC/files
  configure-dnsmasq-dhcp.sh             # port=0, option 6, force=1
  configure-dropbear-ssh.sh             # Port 212
  gfc-routing.sh                        # NAT/DNS 先；TUN 后再 ip rule
  www/cgi-bin/gfc-activation            # CGI → 127.0.0.1:8080（prefer curl）
```

---

## 3. 当前卡在哪

| 项 | 状态 | 说明 |
|----|------|------|
| 含 **r7** 的镜像是否已在构建机编出并刷机 | ⚠️ **当前卡点** | 源码已 push；需 `git pull` + `rebuild-gfc-image.sh` + 刷最新 img.gz |
| 旧镜像 E2E | ⚠️ | 现场可能仍是 r4–r6 或更早：SSH 22、无 hotplug、首启不全 |
| Web 刷码 | ⚠️ 待 r6+ 镜像验证 | busybox wget POST 曾失败；已改 curl；需实机确认无 `flash request failed` |
| 策略路由 | ⚠️ 待激活路径验证 | WAN 无租约 → agent 不激活 → 无 `gfctun` → `ip rule` 仍空（属预期，先修 WAN） |
| SSH 212 | ⚠️ 待 r7 镜像验证 | 源码已修；旧盘需重刷或现场跑 `configure-dropbear-ssh.sh` |
| P1 dist/vmdk 打包 | ❌ 未做 | 可选 |
| 数据面改契约 | 🚫 | 不在本任务范围 |

**一句话：** 构建逻辑与 OEM 源码缺口已修完；**卡在「用 r7 固件重建 + 刷机验收闭环」。**

---

## 4. 下一步计划（严格顺序）

### P0 — 重建并刷含 r7 的镜像（必须）

```bash
export PATH=/usr/local/go/bin:$PATH
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export GOFLAGS=-buildvcs=false

cd /opt/gfc/sip-proxy && git pull
# 若曾用 root 编过：chown -R gfcbuild:gfcbuild /opt/gfc/sip-proxy /opt/gfc/immortalwrt

su - gfcbuild
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

**通过标准：**

```bash
grep gfc-client "$IMT_SRC/bin/targets/x86/64/"*.manifest
# 期望类似: gfc-client - 1.1.0-r7
test -f "$IMT_SRC/build_dir/target-x86_64_musl/root.orig-x86/etc/uci-defaults/99-gfc-firstboot"
test -f "$IMT_SRC/build_dir/target-x86_64_musl/root.orig-x86/etc/hotplug.d/net/99-gfc-tun"
ls -lt "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz | head -3
```

刷机：用**最新时间戳**的 `immortalwrt-x86-64-generic-ext4-combined-efi.img.gz`（勿用旧未压缩 `.img`）。

### P1 — 刷机 E2E 清单

| # | 检查 | 期望 |
|---|------|------|
| 1 | LAN PC DHCP | 拿到地址；DNS 为网关 |
| 2 | `uci get dhcp.@dnsmasq[0].force` | `1` |
| 3 | `nft list tables` | 有 `nat` / `gfc_dns_hijack`（首启后，未激活也可） |
| 4 | Web 激活 | `http://<LAN>/gfc/activate.html` 无 `flash request failed` |
| 5 | WAN | `udhcpc`/`ip a` 有 WAN 地址（否则 activate 卡住） |
| 6 | 激活后 | `ip link show gfctun`；`ip rule` 含 `fwmark 0x2023 lookup 2022` |
| 7 | SSH | **端口 212**（不是 22） |
| 8 | | `verify-dataplane-dns.sh` |

### P2 — 发布打包（可选）

```bash
mkdir -p /opt/gfc/dist/gfc-os-v1
cp "$IMT_SRC/bin/targets/x86/64/"*ext4*combined*efi*.img.gz /opt/gfc/dist/gfc-os-v1/
# gunzip + qemu-img convert → vmdk；sha256sum
```

### P3 — 日常 OTA（已有能力）

- 应用层：`pack-runtime.sh` → `upgrade-runtime.sh`（不必重刷）
- 大版本：新 `img.gz` → `sysupgrade -k`

---

## 5. 踩坑清单 — 新对话不要再踩

### 5.1 构建环境

| 坑 | 正确做法 |
|----|----------|
| 在 **Windows** 编 ImmortalWrt | 必须 **Ubuntu 构建机** |
| **root** 与 **gfcbuild** 混用 | 统一 **gfcbuild**；必要时 `chown -R` |
| Go 用 apt 1.18 | 用 **`/usr/local/go` 1.22+** |
| 无 `GOFLAGS=-buildvcs=false` | OpenWrt build_dir 无 `.git` 会炸 |
| 构建机未 `git pull` | 跑的是旧脚本 → 重复踩已修的坑 |

### 5.2 Feed / Kconfig / 选包

| 坑 | 正确做法 |
|----|----------|
| legacy **`package/gfc/`** | 必须删；只用 **`package/feeds/gfc/`** |
| `feeds update gfc` / `feeds install -a` | **`feeds update -i gfc`** + **`feeds install -f gfc-client luci-app-gfc`** |
| `DEPENDS` 含未索引包（sing-box、sqlite3-cli…） | **整包从 Kconfig 消失**；`DEPENDS` **保持空** |
| `CONFIG_PACKAGE_nftables=y` | 无此 Package；用 **`nftables-json`** + **`kmod-nft-core`** |
| 合并 GFC 后跑 **`make defconfig` / `oldconfig`** | **禁止** — 会清掉 GFC 选包 |
| 以为 packageinfo 有 = 进镜像 | 还要 `.config=y` + **装进 ORIG rootfs** |

### 5.3 rootfs / 镜像 / manifest（最致命一类）

| 坑 | 正确做法 |
|----|----------|
| 只查 **`root-x86`** | **`Image/Manifest` 读 `root.orig-x86`**；注入后必须同步 ORIG |
| `gfc-client.default.install` 写文件列表 | **错误**；只能一行包名 **`gfc-client`** |
| opkg arch 用 `x86` | 必须 **`x86_64`**（与 ipk 名一致） |
| 以为 ipk 是 `ar` | 可能是 **gzip → GNU tar**；需健壮解包 |
| 删 `root-*` 后只 `make target/install` | 须先 **`make package/install`** 再 **`target/linux/install`** |
| `make package/feeds/.../install` | **叶子包无此目标**；用 compile + package/install 或 opkg 注入 |
| 以 **ipk 存在** 当成功 | 唯一标准：**`grep gfc-client *.manifest`** |
| 刷旧 `.img` / dist 拷贝 | 以 **`bin/targets` 最新 img.gz 时间戳** 为准 |

### 5.4 首启 / 设备行为

| 坑 | 正确做法 |
|----|----------|
| 指望 ipk **postinst** 在编镜像时跑 | `IPKG_INSTROOT` 下跳过 → 必须 **`99-gfc-firstboot`** |
| DHCP「found already running… refusing」 | dnsmasq **`force=1`**（`configure-dnsmasq-dhcp.sh`） |
| 刷码后立刻查 `ip rule` 为空就认定 bug | 无 **`gfctun`** 时延迟装规则是**设计**；查 activate/WAN/hotplug |
| CGI `flash request failed` | busybox wget POST 不可靠 → CGI 用 **curl** |
| 线路码 `invalid base32` | 请求体截断/损坏；确认 JSON 完整 |
| SSH 仍 22 | 不是只改 `gfc.env`；要 **dropbear UCI Port=212**（r7） |
| 未激活就等 30s `gfctun` | 拖死 firstboot；未激活应短等 / 跳过 TUN |

### 5.5 架构边界

| 坑 | 正确做法 |
|----|----------|
| 为「方便首启」改 nft 表名/mark/hook | **禁止**；读 `NFT_ARCHITECTURE.md` + 用户确认 |
| 用 MosDNS / sing-box DNS 替代 unbound 服务 LAN | **禁止** |
| kernel-split 开 `auto_route` | **禁止** |
| 用 `docs/draft/*` 覆盖正式 `docs/*_ARCHITECTURE.md` | draft 非正式真相 |

---

## 6. 关键 Git 提交（固件线，新→旧）

```
b28f0f3  fix: policy route on gfctun hotplug; SSH dropbear :212 (r7)
b5f770e  fix: OEM firstboot DHCP/NAT and web flash CGI (r6)
7bb5583  feat: OEM 99-gfc-firstboot (r5)
6199340  fix: sync gfc into root.orig-x86 for Image/Manifest
514497a  fix: gzip+GNU-tar ipk unpack; opkg metadata fallback
627efb9  fix: manifest needs opkg metadata for gfc-client
998bc5b  fix: opkg inject x86_64; robust ipk unpack
8408089  fix: nftables-json not nftables
7084eb7  fix: empty DEPENDS + OEM package index
e8ef7e6  fix: slim DEPENDS for Kconfig
75476ef  fix: drop invalid per-package install; opkg/ipk inject
ff1a259  fix: offline-root opkg inject
2bea409  fix: package/install before target/linux/install
3a5e656  fix: feed setup harden (→ 现 v4)
5bed56a  fix: feeds path + opkg rootfs fallback
54985d0  fix: rebuild-gfc-image.sh; no oldconfig in setup
81947fd  fix: feed setup, GOFLAGS, gfc.env.example
a6fb53e  docs: firmware handoff + Cursor rule
```

---

## 7. 构建机目录与命令速查

```text
/opt/gfc/sip-proxy/              # 本仓库
/opt/gfc/immortalwrt/            # ImmortalWrt 源码树
/opt/gfc/dist/gfc-os-v1/         # 发布目录（手动 cp）
```

```bash
# 一键（推荐）
bash /opt/gfc/sip-proxy/gfc-client/deploy/immortalwrt/scripts/rebuild-gfc-image.sh

# 验收三板斧
grep CONFIG_PACKAGE_gfc-client /opt/gfc/immortalwrt/.config
grep 'Source-Makefile:.*gfc-client' /opt/gfc/immortalwrt/tmp/.packageinfo
# 期望: package/feeds/gfc/gfc-client/Makefile
grep -i gfc /opt/gfc/immortalwrt/bin/targets/x86/64/*.manifest
```

---

## 8. 现网临时救火（不持久，正式仍以重刷为准）

```sh
# SSH 212
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-dropbear-ssh.sh
# 有 gfctun 时补策略路由
GFC_ROUTING_TUN_WAIT=5 /usr/lib/gfc-client/deploy/immortalwrt/gfc-routing.sh start
```

---

*固件构建不修改 nft/unbound/sing-box 数据面契约；若改底层先读 `docs/*_ARCHITECTURE.md` 并出差异表，等用户「确认修改」。*
