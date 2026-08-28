# 会话交接：OEM 固件构建修复 · r16 服务基线 · 激活/认领（2026-07-21）

> 写给**无本对话上下文**的新会话、构建机与现场排障。  
> Cursor 规则：[`.cursor/rules/gfc-firmware-build.mdc`](../.cursor/rules/gfc-firmware-build.mdc)  
> 操作手册：[`gfc-client/deploy/immortalwrt/BUILD-FIRMWARE.md`](../gfc-client/deploy/immortalwrt/BUILD-FIRMWARE.md)  
> 版本策略：[`docs/VERSION_AND_RELEASE.md`](VERSION_AND_RELEASE.md) §1.5  
> 平台生命周期（reclaim/硬退役）：[`docs/SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md`](SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md)

---

## 0. 一句话状态（2026-07-21 末）

| 面 | 状态 | 关键 commit / 产物 |
|----|------|-------------------|
| OEM 固件可进系统、可编过全链路 | **已完成** | `437d990`；`gfc-build-437d990-client-1.1.0-r23-x86-64-ext4-combined-efi.img.gz` |
| r16 必要服务进镜像 | **已完成** | `367063a`–`437d990`：dropbear / openssh / uhttpd / rpcd / odhcpd |
| VMware / 无串口 VGA 启动 | **已完成** | `GFC_VGA_CONSOLE_LAST`；inittab 禁 tty1 respawn / ttyS* |
| package/install / ORIG / rc.common | **已修** | 仅刷新 kernel ipk；保留 base-files；ORIG 同步 rc.d |
| 激活 hard-retired | **控制面流程，非固件 bug** | reclaim → **平台绑线路** → 设备再激活 |
| 产品版本 | **未因试编升号** | 仍为 `gfc-client 1.1.0-r23`；日常构建不 bump rN |

---

## 1. 本会话做了什么任务

### 1.1 固件构建 / rootfs（构建机）

| # | 任务 | 结果 |
|---|------|------|
| 1 | `luci-light` 依赖 `luci-app-firewall` 导致 package/install 失败 | 禁用 `luci` meta / `luci-light` / `luci-ssl*`；LuCI = base + theme + mod-admin-full + luci-app-gfc |
| 2 | VMware 卡在 `Run /sbin/init`、VGA 无输出 | 24.10 cmdline 串口在后 → 注入 **`GFC_VGA_CONSOLE_LAST`**（cmdline 以 `console=tty1` 结尾） |
| 3 | VGA `open: No such file or directory` 刷屏 | 撤销 `tty1::respawn`；注释 ttyS*/hvc* getty |
| 4 | ORIG 缺 `/etc/rc.common`、无 `S*` 启停链 | 根因：ABI 恢复 **`rm -rf bin/.../packages`** 误删 **base-files**；改为只刷新 kernel/kmod；构建断言 staging 有 rc.common |
| 5 | ORIG 有 rc.common 但 `S*` 全为 0 | OpenWrt 在 Enabling 前拷贝 ORIG；**从 TARGET_DIR 同步 `etc/rc.d` → ORIG** 再打包 |
| 6 | 新镜像无 dropbear（`which dropbear` 空） | 禁用 `default-settings` 后不再顺带装 SSH；**显式** `CONFIG_PACKAGE_dropbear=y` |
| 7 | 对照 r16 `service` 列表补必要包 | `gfc-packages.config` + `gfc-initd-baseline.txt` + manifest/ORIG 校验 |
| 8 | `verify_required_gfc_ipks` 报缺 dropbear/openssh | 增量构建不跑全量 `package/compile`；**`build_packages` 显式 compile** 基线包 |
| 9 | `ORIG missing ssh client` 假失败 | openssh 装 `/usr/libexec/*`；alternatives 在 prepare_rootfs；**打包前在 ORIG 建 `/usr/bin/ssh`  symlink** |
| 10 | 版本号误升 | 固化 **§1.5**：试编/排错不 bump 产品号；`gfc-os-v*` 仅 `GFC_PUBLISH_RELEASE=1` |

### 1.2 现场 / 控制面（盒子）

| # | 任务 | 结论 |
|---|------|------|
| 1 | 刷码后 `device was hard-retired` | 线路码**已读到**；控制面拒绝（tombstone）；须 admin **reclaim** |
| 2 | reclaim 后仍离线 | reclaim 只解除墓碑 → 设备 **待分配**（`line_id` 空）；须 **平台绑线路** 后再激活 |
| 3 | `gfctun` down / `control_plane_reachable: false` | 激活前常见；**不是** hard-retired 根因 |

---

## 2. 已经完成了什么（可当作 baseline）

### 2.1 构建脚本与配置

- `config/gfc-packages.config` — r16 基线包 + 注释对照表  
- `config/gfc-package-index.txt` — 与 config 同步  
- `config/gfc-initd-baseline.txt` — ORIG 必须存在的 init.d  
- `scripts/rebuild-gfc-image.sh` — merge 校验、显式 compile 基线、ORIG openssh symlink、init.d/manifest 断言  
- `scripts/ensure-gfc-package-index.sh` — dropbear/uhttpd/rpcd/odhcpd/openssh 索引  
- `scripts/repair-oem-rootfs.sh` — 一次性修 ORIG（应急）  
- `docs/VERSION_AND_RELEASE.md` §1.5 + `.cursor/rules/gfc-version-release.mdc`

### 2.2 推荐刷机镜像（本批验证通过）

```text
/opt/gfc/immortalwrt/bin/targets/x86/64/
  gfc-build-437d990-client-1.1.0-r23-x86-64-ext4-combined-efi.img.gz
  gfc-build-437d990-client-1.1.0-r23-x86-64-ext4-combined-efi.img.gz.sha256
```

与 `immortalwrt-x86-64-generic-ext4-combined-efi.img.gz`（同时间戳）内容同源；**分发用 gfc-build 命名**（含 git sha）。

### 2.3 r16 必要服务 ↔ 包（强制）

| init.d | OpenWrt 包 | 备注 |
|--------|------------|------|
| dropbear | `dropbear` | 端口 212 由 firstboot/configure-dropbear-ssh |
| autossh | `autossh` | 反向 SSH 由 agent 写 `gfc-reverse-ssh` |
| dnsmasq | `dnsmasq-full` | |
| uhttpd / rpcd | `uhttpd` + `rpcd` + luci-base | |
| odhcpd | `odhcpd-ipv6only` | init 名仍为 odhcpd |
| gfc-* | `gfc-client` | agent/api/unbound/sing-box/routing/lan-dhcp |
| firewall | **不装 / disabled** | GFC nft，不用 fw4 |
| stock unbound | **disabled** | `gfc-unbound` 占 :53 |
| autocore/gpio/led/lm-sensors 等 | **不强制** | ImmortalWrt 装饰，非 GFC 必要 |

反向 SSH 额外需要：`openssh-client` + `openssh-keygen`（`/usr/bin/ssh` 由构建脚本 symlink）。

---

## 3. 后续开发必须遵循

1. **版本**：正式发版才 bump `vX.Y.Z` / `PKG_RELEASE` / matrix / tag；**试编、修构建、再刷一盘不升号**（§1.5）。  
2. **禁用 default-settings 后**：凡 r16/stock 曾顺带安装的包，必须在 **`gfc-packages.config` 显式 `=y`**，并在 **`build_packages` 显式 compile**（增量构建不会自动编新选包）。  
3. **ORIG 先于 prepare_rootfs 打包**：凡依赖 **ALTERNATIVES** 的二进制（openssh、tc），构建侧要在 ORIG 补 symlink 或验 `/usr/libexec/*`，不能只看 `/usr/bin/*`。  
4. **ABI/kernel 恢复**：**禁止** `rm -rf bin/targets/x86/64/packages` 后只编 kernel；会抹掉 **base-files**。只删 `kernel_*` / `kmod_*` 或走 `recover-package-install.sh`。  
5. **LuCI**：不用 `luci-light` / `luci` meta；禁 `firewall4` / `luci-app-firewall`。  
6. **数据面**：nft / unbound / sing-box 仍须用户「确认修改」。  
7. **激活生命周期**：hard-retired → reclaim → **平台绑线路** → 设备激活；reclaim  alone 不会在线。  
8. **构建机环境**（每次 rebuild 前）：

```bash
export PATH=/usr/local/go/bin:$PATH
export IMT_SRC=/opt/gfc/immortalwrt
export GFC_REPO=/opt/gfc/sip-proxy/gfc-client
export GOFLAGS=-buildvcs=false
bash "$GFC_REPO/deploy/immortalwrt/scripts/rebuild-gfc-image.sh"
```

9. **分发校验**：在镜像目录执行 `sha256sum -c`（见 §4.2）。

---

## 4. 验收命令

### 4.1 构建机（编完）

```bash
cd /opt/gfc/sip-proxy && git rev-parse --short HEAD   # 期望 ≥ 437d990（本批功能）
grep -E '^(gfc-client|dropbear|openssh-client|openssh-keygen|uhttpd|rpcd|odhcpd)' \
  "$IMT_SRC/bin/targets/x86/64/"*.manifest
grep PKG_RELEASE gfc-client/deploy/immortalwrt/package/Makefile   # 当前 r23
ls -lh "$IMT_SRC/bin/targets/x86/64/gfc-build-"*.img.gz
```

### 4.2 校验和（必须在镜像目录）

```bash
cd /opt/gfc/immortalwrt/bin/targets/x86/64
sha256sum -c gfc-build-437d990-client-1.1.0-r23-x86-64-ext4-combined-efi.img.gz.sha256
```

在其他目录跑 `-c` 会因 **相对路径** 报 `No such file`——**不是镜像损坏**。

### 4.3 刷机后（r16 基线）

```bash
which dropbear
ls /etc/init.d/{dropbear,uhttpd,rpcd,odhcpd,gfc-agent,gfc-api,gfc-unbound}
grep -E '^Package: (dropbear|openssh-client)' /usr/lib/opkg/status
uci get dropbear.@dropbear[0].Port    # 212
```

### 4.4 激活 / 认领（控制面 + 盒子）

```bash
# 盒子
logread -e gfc-agent | tail -30
ls -la /etc/gfc-client/activation.b32 /etc/gfc-client/lib/state/client_state.json

# 错误对照
# hard-retired          → reclaim（device_key 与 MAC 一致）
# line binding revoked  → 平台先绑线路，再激活
# activated line=...    → 等心跳，平台应变在线
```

---

## 5. 踩坑清单 — 不要再踩

### 5.1 构建 / rootfs

| 坑 | 正确做法 |
|----|----------|
| ABI 恢复删掉整个 `packages/` | 只删 **kernel/kmod** ipk；**base-files 必须在** |
| 以为 Enabling 时 `rc.common: No such file` = 镜像坏 | 可能是 offline quirk；**断言 ORIG 文件存在** + 同步 rc.d |
| 禁用 default-settings 后 SSH 还在 r16 列表里 | **不会自动进镜像**；须 `CONFIG_PACKAGE_dropbear=y` + compile |
| 在 config 加了新包但未改 `build_packages` | `verify_required_gfc_ipks` 会 **MISSING ipk** |
| openssh 已装但 ORIG 无 `/usr/bin/ssh` | 正常；打包前 **`ensure_openssh_runtime_paths`** |
| `CONFIG_GRUB_SERIAL is not set` 以为关了串口优先 | 24.10 上常 **无此符号**；靠 **GFC_VGA_CONSOLE_LAST** |
| tty1 respawn 导致 VMware open 刷屏 | inittab 用 **askfirst** 或禁 tty1 respawn |
| Ctrl+C 打断**第二次** rebuild | **已完成的 img.gz 不受影响**；下次 rebuild 若 tmp 脏可 `make prepare` |
| `sha256sum -c` 在非镜像目录 | **`cd` 到 img 所在目录** 或用绝对路径 hash |
| 用 squashfs 镜像刷 GFC OEM | 用 **ext4 combined-efi** |
| 未设 `GFC_REPO` 跑 rebuild | 默认 `/opt/gfc/sip-proxy/gfc-client`；空变量会路径错误 |
| 试编成功就 bump r24 / 切 v1.1.9 | **违反 §1.5**；正式发版才升 |

### 5.2 激活 / 生命周期

| 坑 | 正确做法 |
|----|----------|
| 有 `activation.b32` 就认为「没读码」 | 看 log 是 **activate error** 还是根本没 POST |
| reclaim 后期望自动在线 | 须 **PATCH 绑 line_id** + 设备 **再激活** 拿 token |
| 把 `gfctun` down 当激活失败原因 | 先解 **hard-retired / binding_revoked** |
| 同一 MAC 新 VM 仍 hard-retired | **device_key 来自 MAC**；须 reclaim 同一 key |
| Web 重启 agent 等价于清 state | 仍保留本地 token/state；401 才会清 state |

---

## 6. 关键路径速查

| 能力 | 路径 |
|------|------|
| 选包 | `gfc-client/deploy/immortalwrt/config/gfc-packages.config` |
| init.d 基线 | `gfc-client/deploy/immortalwrt/config/gfc-initd-baseline.txt` |
| 一键构建 | `gfc-client/deploy/immortalwrt/scripts/rebuild-gfc-image.sh` |
| 应急修 ORIG | `gfc-client/deploy/immortalwrt/scripts/repair-oem-rootfs.sh` |
| 激活 API | `gfc-platform/control-plane/api/app/clients.py` `/activate` |
| reclaim API | `gfc-platform/control-plane/api/app/admin.py` `/client-devices/reclaim` |
| agent 激活 | `gfc-client/internal/agent/runner.go` |
| PKG_RELEASE | `gfc-client/deploy/immortalwrt/package/Makefile` |

---

## 7. 建议的新会话开场白

> 读 `docs/SESSION_HANDOFF_2026-07_FIRMWARE_BUILD_FIXES.md` 与 `.cursor/rules/gfc-firmware-build.mdc`。  
> 固件以 **`gfc-build-<gitsha>-client-1.1.0-r23-*ext4*combined*efi*.img.gz`** 为准；manifest 含 dropbear/openssh/uhttpd。  
> 试编不升版本（§1.5）；改 nft/unbound/sing-box 须确认修改。  
> 激活失败：hard-retired → reclaim → **平台绑线路** → 再激活。

---

## 8. 相关 commit（main，约序）

| commit | 摘要 |
|--------|------|
| `437d990` | ORIG 打包前 openssh `/usr/bin` symlink |
| `78de7cc` | build_packages 显式 compile dropbear/openssh 等 |
| `367063a` | r16 服务基线选包 + init.d 校验 |
| `bf7b66f` | CONFIG_PACKAGE_dropbear |
| `67ab467` | TARGET_DIR → ORIG 同步 rc.d |
| `dbffefc` | VERSION §1.5 试编不升号 |

（更早：VGA console、base-files/rc.common、luci-light 等见 git log `gfc-client/deploy/immortalwrt/`）
