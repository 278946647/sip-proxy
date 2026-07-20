# GFC Changelog（产品版本）

按 [`VERSION_AND_RELEASE.md`](../VERSION_AND_RELEASE.md) 追加。每条对应 Git tag `vX.Y.Z`。

格式：

```
## [X.Y.Z] - YYYY-MM-DD

### 级别
Patch | Minor | Major | Dataplane-Arch

### 组件钉扎
- control_plane_api: …
- node_agent: …
- gfc_client: …

### 变更
- …

### 升级
- 同 Major 直升：是/否
- 跨 Major 路径：…
- OTA 基线：…

### 验收探针
- …
```

---

## [1.1.2] - 2026-07-20

### 级别
Patch

### 组件钉扎
- control_plane_api: 0.1.0
- node_agent: 0.3.1
- gfc_client: 1.1.0-r17

### 变更
- OEM 固件 opkg 源改为官方 `downloads.immortalwrt.org` ImmortalWrt **24.10.6** x86/64（不再用 `mirrors.vsean.net`）
- 固件预装 `kmod-tcp-bbr` + `kmod-sched`，写入 `/etc/sysctl.d/12-gfc-bbr.conf`，首启启用 TCP BBR（`fq` + `bbr`）

### 升级
- 同 Major 直升：是（`1.1.1` → `1.1.2`）
- 跨 Major 路径：无
- OTA 基线：仍为 `1.1.0`；本版 BBR/opkg 源以 **刷 OEM 固件** 为准（Runtime OTA 可带上 distfeeds/sysctl，但 kmod 需镜像预装）

### 验收探针
- 固件 manifest：`gfc-client - 1.1.0-r17`
- `grep downloads.immortalwrt.org /etc/opkg/distfeeds.conf`（无 vsean）
- `opkg list-installed | grep kmod-tcp-bbr`
- `sysctl -n net.ipv4.tcp_congestion_control` → `bbr`

---

## [1.1.1] - 2026-07-19

### 级别
Patch

### 组件钉扎
- control_plane_api: 0.1.0
- node_agent: 0.3.1
- gfc_client: 1.1.0-r16

### 变更
- Runtime OTA：安装期不再中途停止/pkill `gfc-api`/`gfc-agent`，避免父进程管道 SIGPIPE 导致半装
- 安装日志落盘 `ota-install.log`；成功/失败 marker `ota-result.json`（重启控制面前写入）
- Agent 对已达目标版本或 marker 命中短路 ack，避免重复整包

### 升级
- 同 Major 直升：是（`1.1.0` → `1.1.1`）
- 跨 Major 路径：无
- OTA 基线：仍为 `1.1.0`；本版可 OTA 或刷 `1.1.0-r16` OEM 图

### 验收探针
- 见 [`notes/v1.1.1.md`](notes/v1.1.1.md) 验收检查清单
- 固件 manifest：`gfc-client - 1.1.0-r16`
- OTA 后：`/var/lib/gfc-client/state/ota-result.json` → `status=ok`

---

## [1.1.0] - 2026-07-16

### 级别
Minor（相对历史 v1.0.0 tag；本规范起始基线）

### 组件钉扎
- control_plane_api: 0.1.0
- node_agent: 0.3.1
- gfc_client: 1.1.0-r15

### 变更
- 线路/设备生命周期（绑定守卫、软重置、硬退役 reclaim）
- Runtime OTA 一期（制品库、单设备下发、进度轮询）
- VLESS 出口检测（国内直联 + SOCKS/节点双期望）

### 升级
- 同 Major 直升：是（Major 1）
- 跨 Major 路径：无（当前无 v2）
- OTA 基线：本版本；更旧无 OTA 能力的盒子须先人工 install.sh / 刷机

### 验收探针
- 客户端 `GET /api/v1/upgrade/status`
- `POST /api/v1/diagnostics/vless` 含 `expected_ip` / `socks_ip`
- 固件 manifest：`gfc-client - 1.1.0-r15`
