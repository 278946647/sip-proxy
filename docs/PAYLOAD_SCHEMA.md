# PAYLOAD_SCHEMA（AmneziaWG 迭代 · P0 草案）

> 状态：**草案**（2026-11-26 按用户指令已落地实现，字段仍以联调结果为准；实装后需回填确认）。
> 本文件是 P0-1 的契约草案，不改动任何现有规范与代码路径。
> 依据：[`rollout-plan-v1.2.md`](../2026-11-23/amneziawg-rollout/outputs/rollout-plan-v1.2.md) §4.1、§5.1–§5.10 与 [`amneziawg-dev-constraints.mdc`](../2026-11-23/amneziawg-rollout/outputs/amneziawg-dev-constraints.mdc)。
> **已确认边界**：出口切换只换 `table 2022` 的 default 设备，不新增 mark/路由表；不存在自动切换；`target` 仍只有 `reality`。
> 标注【待定】的字段必须在联调时确认。

## 1. 不变量

| 项 | 约定 |
|---|---|
| `transport` 取值 | 只有 `reality`（默认）/ `awg`；**不存在 `hy2`** |
| 自动切换 | 不存在。`autoSwitch` 固定 `false`，`healthProbe.reportOnly` 固定 `true` |
| 手动切换目标 | 只有 `reality`；`manualSwitchTargets=["reality"]` |
| 内层标识 | 每条 awg 线路一个节点内唯一 `/32`（`awg_inner_ip`），只作隧道内层标识，不是线路身份 |
| 出口接入 | 复用 `mark 0x2023` → `table 2022`；只切换该表 `default` 设备（`gfctun` / `awg0`） |
| 参数一致性 | `paramsVersion` + `obfuscation` + `serverPublicKey` 参与 `awgChecksum`，两端不一致拒绝应用 |
| 私钥 | 只加密存储；仅首次/轮换随 payload 下发一次；不进 UI、审计、metrics、错误信息 |

## 2. Node payload 新增字段

在现有 node payload 基础上新增（现有字段不改名）：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `configSchemaVersion` | int | 是 | 节点 payload 结构版本；草案值 **【待定】** |
| `transport` | string | 是 | 节点上存在启用中的 awg peer 时为 `awg`，否则 `reality` |
| `awg` | object | `transport=awg` 时必填 | 见下表 |
| `awg.enabled` | bool | 是 | 节点是否启用 AWG |
| `awg.iface` | string | 是 | 固定 `awg0` |
| `awg.listenPort` | int | 是 | 默认 `51820/udp`，不得与 `18443/udp` 冲突 |
| `awg.serverInnerIp` | string | 是 | 示例 `10.66.0.1/24` |
| `awg.mtu` | int | 是 | 默认 `1408`，允许 `1280..1420` |
| `awg.paramsVersion` | int | 是 | 参数组版本 |
| `awg.obfuscation` | object | 是 | `jc/jmin/jmax/s1/s2/h1..h4`（可选 `s3/s4`），整组下发 |
| `awg.checksum` | string | 是 | 见 §6 |
| `awg.peers[]` | array | 是 | 每项含 `lineId`、`innerIp`（`/32`）、`publicKey`、`presharedKey`（可空） |
| `tproxyIface` | string | 是 | 存在启用中的 awg peer 时为 `awg0`；否则保持现状 |
| `dataplane.rules[].source_ip_cidr` | string | 否 | awg 线路用其 `/32` 作为分流键；reality 线路仍走 `auth_user` |

约束：
- `awg.peers` 只包含 `transport=awg` 且 `status=active` 的线路；不得把 awg `/32` 混入 reality 的 VLESS/Hy2 用户列表。
- `payload_version` 算法不变；`awg` 块参与哈希，参数变化必须触发重下发。
- 节点拒绝应用时保持上一版配置，不重启 `gfc-sing-box`。

## 3. Client payload 新增字段

`transport=reality` 时**不输出** `awg` 块，保持旧 payload 兼容。

```jsonc
{
  "configSchemaVersion": 3,          // 草案值；D-10 冻结
  "transport": "awg",
  "autoSwitch": false,               // 固定 false
  "manualSwitchTargets": ["reality"],
  "minFirmwareVersion": "2.2.0",
  "awg": {
    "iface": "awg0",
    "innerIp": "10.66.12.7/32",
    "endpoint": "203.0.113.10:51820",
    "privateKey": "<base64>",        // 仅首次/轮换下发
    "serverPublicKey": "<base64>",
    "presharedKey": "<base64|null>",
    "paramsVersion": 3,
    "obfuscation": { "jc": 4, "jmin": 40, "jmax": 70, "s1": 30, "s2": 40,
                     "h1": 1, "h2": 2, "h3": 3, "h4": 4 },
    "checksum": "<sha256>",
    "mtu": 1408,
    "persistentKeepalive": 25
  },
  "healthProbe": {
    "intervalSec": 10,
    "reportOnly": true,              // 固定 true
    "targets": ["nodeInnerIp", "dns"],
    "thresholds": {
      "handshakeAgeWarnSec": 180,
      "handshakeAgeCritSec": 600,
      "probeFailCount": 3,
      "lossWarnPct": 5
    }
  }
}
```

明确不输出：`transport=hy2`、`hy2_transport_enabled`、`outboundPolicy`、任何“自动切换”语义字段。
盒子收到任何自动切换字段必须忽略并上报配置错误。

## 4. `configSchemaVersion` 规则

1. **只增不改**：新增可选字段不升版本；删除、改名、改变字段语义或必填性必须 +1。
2. **向下不兼容**：盒子收到高于自身支持的版本时，**不应用**，保留上一份可用配置，上报 `unsupported_transport` / `unsupported_schema`。
3. 控制面按下发对象分别维护 node / client 两个版本号，不共用一个值。
4. 当前草案值：client 拟 **3**（沿用 v1.2 示例）；node **【待定】**（以现有 payload 基线 +1 为准）。
5. 版本号变更属于数据面契约变更，按 D-08 走 Dataplane-Arch 定级与兼容矩阵。

## 5. 兼容矩阵（下发前闸门）

| 固件版本 | 支持 transport | 允许下发 awg | 处理 |
|---|---|---|---|
| `< 2.2.0` | `reality` | 否 | 拒绝创建 awg 线路；已有 awg 线路禁止绑定该设备 |
| `>= 2.2.0` | `reality` / `awg` | 是 | 正常 |
| 未知/未上报 | `reality` | 否 | 按 reality 处理，UI 提示升级 |

闸门位置：`create_line` / 绑定设备 / `upgrade_client_device` / `switch-transport` 四处。
`min_firmware_version` 只做渲染期快速拒绝；权威判定以 `docs/releases/VERSION_MATRIX.json` 与设备上报组件版本为准。

## 6. 校验和与拒绝规则

`awgChecksum = sha256(canonical_json({paramsVersion, obfuscation, serverPublicKey}))`，完整 64 位十六进制。

拒绝应用的场景（保留上一份配置并上报，不改变 `transport`）：
- `transport` 不在 `{reality, awg}`；
- `configSchemaVersion` 高于本地支持；
- `obfuscation` 缺字段、含未知字段、越界、`jmin > jmax`、`h1..h4` 重复；
- 本地计算的 `checksum` 与 payload 不一致；
- `awg_inner_ip` 非单主机 `/32`；
- `transport=awg` 但缺少 `awg` 块或 `awg.peers` 为空。

## 7. 健康指标契约（只读采集，不触发切换）

采样周期建议 `10s`；阈值全部可配置，默认值如下。

| 指标 | 单位 | warn | critical | 说明 |
|---|---|---|---|---|
| `handshake_age_sec` | 秒 | `> 180` 且期间无 rx/tx 增量 | `> 600` | 只表述“最近握手距今 N 秒” |
| `probe_fail_count` | 次 | `>= 3`（约 30s） | `>= 5`（约 50s） | 连续失败计数 |
| `rx/tx_stall` | 分钟 | `5` 分钟增量为 0 | `15` 分钟增量为 0 | 需与 `/32` 流量对照 |
| `loss_pct` | % | `> 5`（5 分钟窗口） | `> 10` | 人工决策依据 |
| `rtt_p95_ms` | ms | `> 200` | `> 400` 或较 reality 基线增量 `> 100` | — |
| `dns_fail_pct` | % | `> 10`（5 分钟） | `> 30` | 与 DNS 路径联动 |
| `conntrack_usage_pct` | % | `> 70` | `> 90` | 两端 |
| `awg_iface_up` | bool | down 或不存在 | 持续 down `> 60s` | 接口状态 |
| `peer_count_gap` | 个 | 少 1 | 少 `>= 2` 或少在用线路 | 控制面期望值 vs 两端实际 |
| `config_checksum_match` | bool | 不一致 | 持续不一致 `> 2` 个轮询周期 | 应用失败归入此项 |

禁止字段：`connected`、`session_state`、`online` 及任何无法从无连接协议推导的状态。

## 8. 手动切换契约

唯一写入口：`POST /lines/{id}/switch-transport`。

| 字段 | 类型 | 必填 | 规则 |
|---|---|---|---|
| `target` | string | 是 | 只接受 `reality`（`pattern="^reality$"`） |
| `reasonCategory` | string | 是 | `udp_blocked` / `packet_loss` / `latency` / `maintenance` / `other` |
| `reasonText` | string | 是 | 非空 |
| `confirmImpact` | bool | 是 | 必须为 `true` |
| `expectedFromTransport` | string | 是 | 乐观锁；与当前值不一致则拒绝 |

结果状态：`pending` / `applied` / `verified` / `failed` / `superseded`。
- 验证入口：`POST /lines/{id}/switch-transport/{switchId}/verify`。
- 验证失败只标记 `failed`，**不自动回滚、不自动切回 AWG**。
- 每次切换同时写 `TransportSwitchLog` 与 `OperationLog`；不记录私钥。
- 检测与执行彻底分离：健康状态只作展示与快照，不作为拒绝条件。

## 9. 恢复 AWG（已实装为“配置恢复”，不是切换目标）

本期 `target` **仍只有 `reality`**。恢复 AWG 走独立接口：
`POST /lines/{id}/transport/reapply-awg`，要求线路已有可用 `AwgPeer`，写 `TransportSwitchLog(from=reality, to=awg)`，UI 表述为“恢复 AWG 配置”。
该接口不参与自动切换，也不在健康检测触发路径中。

## 10. 待确认清单

| 项 | 阻塞 |
|---|---|
| `configSchemaVersion` 的 node/client 基线值 | P0 冻结 |
| `awg_checksum` 是否进入 `payload_version` 哈希 | P1 渲染 |
| `target=awg` 是否采纳方案 B（D-11） | P1/P4 |
| 私钥加密方案（复用 `platform_secrets` / `vpn_pki`？） | P1 安全 |
| 指标上报接口与存储位置 | P4 |
| `awg_inner_ip` 是否允许 IPv6 | 本期约定仅 IPv4 |

## 11. 冻结检查清单

- [ ] D-01 ~ D-11 均有明确结论。
- [ ] node / client 两个 `configSchemaVersion` 值确定。
- [ ] `awg` 块字段名、必填性、默认值三方（节点/盒子/控制面）无歧义。
- [ ] 指标名、单位、阈值、窗口与采样周期写入两端代码常量来源。
- [ ] 手动切换接口字段与 `TransportSwitchLog` 字段对齐。
