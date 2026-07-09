# GFC Client — OpenWrt / ImmortalWrt 网络 Apply 规范

> **版本**: v1.0  
> **范围**: `gfc-bootstrap --apply-network`、`gfc-bootstrap --rollback-network`、`/etc/gfc-client/network-wan.json`  
> **平台**: ImmortalWrt / OpenWrt（`GFC_PLATFORM=immortalwrt`）  
> **状态**: 生产契约；实现与 AI 生成必须以之为准

---

## 1. 背景与事故教训

2026-03 生产事故：`gfc-bootstrap --apply-network` 在缺少 `network-wan.json` 时按默认 `mode=dhcp` 写 UCI，但设备实际为 **static**（UCI 残留 `ipaddr/gateway` 且 `proto` 不一致），`network restart` 后 **WAN 丢 IP**。

LuCI GFC「回滚配置」仅回滚 **数据面**（`/dataplane/rollback`），**不能**恢复 `/etc/config/network`。

本规范固化安全 apply 流程，防止模式切换时 UCI 字段残留。

---

## 2. 两种「回滚」不可混淆

| 操作 | 命令 / API | 恢复对象 |
|------|------------|----------|
| **数据面回滚** | LuCI GFC「回滚配置」、`/dataplane/rollback` | sing-box / unbound / nft 等业务配置 |
| **系统网络回滚** | `gfc-bootstrap --rollback-network` | `/etc/config/network` 快照（含 WAN/LAN UCI） |

改 WAN 前必须依赖 **网络快照**；数据面回滚 **不替代** 网络回滚。

---

## 3. Apply 流程（强制顺序）

`applyOpenWrt()` 必须按以下顺序执行：

```
1. ensureWANConfigFromUCI()     # network-wan.json 缺失时从 UCI 导入，禁止盲写 dhcp
2. snapshotOpenWrtNetwork()     # 写 WAN 前备份 /etc/config/network（仅当 network-wan.json 存在）
3. applyOpenWrtWAN()            # 按 JSON mode 写 UCI，并清理跨模式残留字段
4. （可选）LAN/DHCP             # 仅 GFC_MANAGE_LAN=1
5. routes / vlan
6. disable stock fw4（`disableOpenWrtFW4`，不 restart firewall）
7. uci commit network/dhcp + network/dnsmasq restart
8. reversessh restore 标记      # apply-network / upgrade 后由 agent 恢复隧道
```

### 3.1 WAN 写入前置条件

- **有** `network-wan.json`（或本次 seed 成功）：允许写 WAN，且必须先快照。
- **无** `network-wan.json` 且 seed 失败：若 `GFC_MANAGE_WAN=1` 则 **报错退出**；否则 **跳过 WAN**，不得默认写 dhcp。

### 3.2 LAN 默认不触碰

- 除非 `GFC_MANAGE_LAN=1`，不得修改 `network.lan`、`dhcp.lan`。
- 避免 apply-network 意外改 LAN 网段或 DHCP。

---

## 4. `network-wan.json` 契约

路径：`/etc/gfc-client/network-wan.json`

### 4.1 公共字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `enabled` | bool | 是否启用 WAN 段（导入/展示用） |
| `interface` | string | UCI `network.wan.device`；空则用 `GFC_WAN_IFACE` |
| `mode` | string | `static` \| `dhcp` \| `pppoe` |
| `mtu` | int | 可选；`<=0` 时删除 UCI `mtu` |

### 4.2 按 mode 的字段

| mode | JSON 字段 | UCI 映射 |
|------|-----------|----------|
| `static` | `address`, `netmask`, `gateway`, `dns1`, `dns2` | `ipaddr`, `netmask`, `gateway`, `dns`（空格拼接） |
| `dhcp` | （无额外字段） | `proto=dhcp` |
| `pppoe` | `username`, `password` | `username`, `password` |

### 4.3 示例

**Static**

```json
{
  "enabled": true,
  "interface": "eth0",
  "mode": "static",
  "address": "103.78.41.17",
  "netmask": "255.255.255.224",
  "gateway": "103.78.41.1",
  "dns1": "223.5.5.5",
  "dns2": "8.8.8.8"
}
```

**PPPoE**

```json
{
  "enabled": true,
  "interface": "eth0",
  "mode": "pppoe",
  "username": "user@isp",
  "password": "secret",
  "mtu": 1492
}
```

**DHCP**

```json
{
  "enabled": true,
  "interface": "eth0",
  "mode": "dhcp"
}
```

---

## 5. UCI 字段清理矩阵（强制）

切换 `mode` 时必须删除**不属于当前模式**的 UCI 选项，防止 `proto` 与地址字段不一致。

实现入口：`buildWANApplyPlan()` → `applyOpenWrtWAN()`（`internal/network/openwrt_wan.go`）

| 目标 mode | 写入 | 必须删除 |
|-----------|------|----------|
| `static` | `ipaddr`, `netmask`, `gateway`, `dns` | `username`, `password` |
| `dhcp` | `proto=dhcp` | `ipaddr`, `netmask`, `gateway`, `dns`, `username`, `password` |
| `pppoe` | `username`, `password` | `ipaddr`, `netmask`, `gateway`, `dns` |

空 JSON 字段 → `uci delete` 对应键（不写空字符串占位）。

---

## 6. UCI 导入（Seed）

`ensureWANConfigFromUCI()`：当 `network-wan.json` **不存在**时，从 `uci show network.wan` 解析并生成 JSON。

必须支持导入：

- `proto`: `static` / `dhcp` / `pppoe`
- static: `ipaddr`, `netmask`, `gateway`, `dns`
- pppoe: `username`, `password`

Seed 成功后方可进入 WAN apply；这是避免「无 JSON 却写 dhcp」的关键。

---

## 7. 网络快照与回滚

### 7.1 快照

- 时机：每次 apply WAN **之前**（且 `network-wan.json` 存在）
- 路径：`{BackupsDir}/network-{UTC时间}/network`
- 保留：最近 **10** 份（`pruneNetworkSnapshots`）

### 7.2 回滚

```sh
GFC_PLATFORM=immortalwrt gfc-bootstrap --rollback-network
```

- 恢复最新快照到 `/etc/config/network`
- `uci commit` network/dhcp/firewall
- `network` / `dnsmasq` / `firewall` restart

仅 OpenWrt/ImmortalWrt 支持；Ubuntu 路径走 `deploy/apply-network.sh`。

---

## 8. 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `GFC_MANAGE_LAN` | `0` | `1` 时才 apply LAN + dhcp.lan |
| `GFC_MANAGE_WAN` | 见实现 | WAN JSON 缺失且 seed 失败时是否硬失败 |
| `GFC_WAN_IFACE` | 自动发现 | `network.wan.device` 回退 |
| `GFC_PLATFORM` | 自动检测 | `immortalwrt` 走 UCI apply |

---

## 9. 测试要求

修改 `internal/network/*` 中 WAN apply 逻辑时，**必须**补充/更新单元测试：

| 测试 | 文件 | 覆盖 |
|------|------|------|
| `TestBuildWANApplyPlanStatic` | `openwrt_wan_test.go` | static 写 + 删 pppoe |
| `TestBuildWANApplyPlanPPPoE` | `openwrt_wan_test.go` | pppoe 写 + 删 static |
| `TestBuildWANApplyPlanDHCP` | `openwrt_wan_test.go` | dhcp 删 static + pppoe |
| `TestParseUCIShowPPPoEWAN` | `openwrt_snapshot_test.go` | UCI seed 解析 |

计划逻辑集中在 `buildWANApplyPlan()`，**禁止**在 `applyOpenWrtWAN()` 内散落未测试的分支。

本地验证：

```sh
cd gfc-client/internal/network && go test -v .
```

---

## 10. 运维检查清单

Apply 前：

1. `uci show network.wan` — 确认当前 proto 与字段
2. 确认 `network-wan.json` 存在或可被 seed
3. 确认有快照目录写权限

Apply 后：

1. `uci show network.wan` — proto 与字段与 mode 一致
2. `ip addr show dev <wan>` — 地址正常
3. 反向 SSH / 控制面心跳 — 隧道恢复（P2-4）

故障时：

```sh
gfc-bootstrap --rollback-network
```

---

## 11. 相关文档

- [`deploy/immortalwrt/README.md`](../deploy/immortalwrt/README.md) — 设备部署与 apply 命令
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Client 总架构（隧道恢复 P2-4）
- [`../../gfc-platform/docs/REMOTE_ACCESS.md`](../../gfc-platform/docs/REMOTE_ACCESS.md) — 远程运维与 apply-network 说明

---

## 12. 禁止事项（未经评审 + 用户批准）

- 在 `network-wan.json` 缺失时默认写 `proto=dhcp`
- apply WAN 时不做 `/etc/config/network` 快照
- 切换 mode 时不清理跨模式 UCI 字段
- 将 LuCI「回滚配置」描述为可恢复系统 network UCI
- 未经 `GFC_MANAGE_LAN=1` 修改 LAN/DHCP
- 把 WAN apply 逻辑从 `buildWANApplyPlan()` 拆散到不可测试的 shell 片段
