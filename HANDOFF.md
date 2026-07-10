# Session Handoff — Global Routing Mode (2026-07-10)

> 写给**完全没有上下文**的新会话。阅读本文即可接续「GFC 网关全局代理模式」相关工作。

---

## 1. 项目背景（30 秒）

- **仓库**：`sip-proxy`（GFC 企业网关 + 控制平台 + 转发节点）
- **产品形态**：ImmortalWrt / Ubuntu 上的 GFC Client 网关盒子，网关模式 + 内核分流数据面
- **默认数据面**：`GFC_ROUTING_SCHEME=kernel-split`
  - nft 用 `TO_CN` 集让国内 IP **直连 WAN**
  - 国际 IP 打 `fwmark 0x2023` → `table 2022` → `gfctun` → sing-box VLESS
- **权威架构文档**（改 nft/sing-box/unbound 前必须先读）：
  - `docs/NFT_ARCHITECTURE.md`
  - `docs/SINGBOX_ARCHITECTURE.md`
  - `docs/UNBOUND_ARCHITECTURE.md`
  - `.cursor/rules/*-no-change-without-approval.mdc`

---

## 2. 本会话要做什么

在现有 **分流模式（split）** 上，完善 **全局模式（global）**：

- **global 含义**：所有公网 IP 流量（含国内）都走代理节点（TUN → VLESS）
- **硬约束**：`bypass_ip` 必须完备（转发节点、控制平台等），否则 VLESS 隧道无法建立
- **DNS**：即使 IP 全局代理，**unbound 国内/国际解析分流不变**（用户明确：不必单独做 DNS 全局配置）

---

## 3. 方案决策（已定论，勿重开辩论）

曾讨论两种实现：

| 方案 | 做法 | 结论 |
|------|------|------|
| A | 改 main 路由表默认 → `gfctun`，bypass 写静态路由 | ❌ 不推荐：与 netifd 冲突、与 fwmark 架构不一致、历史上有环路/CPU 打满教训 |
| B | nft 去掉 `@TO_CN return`，国内 IP 也打标进 TUN | ✅ **采用** |

**B 的要点**：保留 `fwmark + table 2022`、链名、mark 值、bypass 规则；仅按 `routing_mode` 省略两条 `@TO_CN return`（prerouting + output）。

---

## 4. 已完成内容

### 4.1 分析与文档

- 输出过 **规范 vs 当前实现** 差异表（nft / env / CP→Client 同步链 / DNS）
- 更新 `docs/NFT_ARCHITECTURE.md`：新增 `split` vs `global` 小节

### 4.2 代码实现（已 commit + push）

| 组件 | 文件 | 变更摘要 |
|------|------|----------|
| nft 生成（Ubuntu） | `gfc-client/deploy/gen-nft-policy.py` | `render_architecture()`：`routing_mode=global` 时省略 `@TO_CN return` |
| nft 应用（ImmortalWrt） | `gfc-client/deploy/immortalwrt/gfc-routing.sh` | `load_routing_mode()` 读 `routing-mode.json`；同上逻辑 |
| 控制面 bundle | `gfc-platform/control-plane/api/app/client_config.py` | 增加 `routingScheme`、`controlPlaneServers` |
| 盒端同步 | `gfc-client/internal/orchestrator/orchestrator.go` | `applyRoutingModeFromPayload()` 写 `routing-mode.json` |
| 解析 | `gfc-client/internal/payload/mode.go` | `RoutingMode()` 读 `routingScheme` / `routing_scheme` |
| 测试 | `gfc-client/deploy/tests/test_gen_nft_policy.py`、`mode_test.go`、`test_client_config.py` | global/split nft、bundle 字段 |
| UI | `gfc-platform/web-ui/.../ClientDeviceDetailPage.tsx` | 去掉「待客户端版本支持后生效」 |

### 4.3 Git

| 项 | 值 |
|----|-----|
| 功能提交 | `731fee3` — `feat(client): add global routing mode via nft TO_CN bypass removal` |
| 已 push | `main` → `origin/main` |
| **回滚点（功能开发前）** | 标签 `rollback/pre-global-routing-20260710` → `3756ccd` |

回滚命令：

```bash
git checkout rollback/pre-global-routing-20260710
# 或
git reset --hard rollback/pre-global-routing-20260710
```

### 4.4 字段命名约定（不要再发明新名字）

| 层 | 字段 | 值 |
|----|------|-----|
| 控制面 DB / Admin API | `routing_scheme` | `split` \| `global` |
| Config bundle JSON | `routingScheme` | camelCase，与 `proxyMode` 一致 |
| 盒端文件 | `/etc/gfc-client/routing-mode.json` → `mode` | `split` \| `global` |
| 盒端 SQLite / 本地 UI | `routing_mode` | 仅本地 API/LuCI 用 |

数据面方案 **不是** 流量模式：`GFC_ROUTING_SCHEME=kernel-split` 保持不变。

---

## 5. 当前卡在哪 / 未完成

| 项 | 状态 |
|----|------|
| **生产环境实测** | ❌ 本会话未在真实 GFC 盒子 + 控制平台上跑完验证 |
| 开发机 Windows | 无 `go` / `python` 命令，单元测试未在本地执行 |
| `docs/draft/*` | 未纳入 commit（SINGBOX/UNBOUND draft + mdc），与本次功能无关 |
| bypass fail-safe | 未做（global 下 bypass 为空时拒绝切换） |
| Reality SNI IP 系统化进 bypass | 未做 |
| `NFT_ARCHITECTURE.md` 变更 | 已写入；若严格遵循 approval 流程，后续大改仍需用户确认 |

**功能代码已合入 main，但「上线可用」需部署 + 验证闭环。**

---

## 6. 下一步计划（建议顺序）

### 6.1 部署

1. 控制平台：部署含 `731fee3` 的 API
2. GFC 盒子：升级 client（`upgrade-runtime.sh` 或等价流程）
3. 确认 agent 运行且能拉 `/clients/me/config`

### 6.2 端到端验证（需 **控制平台 + 盒子** 同时参与）

```bash
# --- 控制平台：设 global ---
# Web UI：设备详情 → 业务路由模式 → global → 保存
# 或 PATCH /api/admin/client-devices/{id}  body: {"routing_scheme":"global"}

# --- 盒子 ---
cat /etc/gfc-client/routing-mode.json                    # 期望 {"mode":"global"}
python3 -c "import json; p=json.load(open('/var/lib/gfc-client/state/config_bundle.json'))['payload']; print(p.get('routingScheme'), p.get('controlPlaneServers'))"

nft list chain inet gfc prerouting_mangle_route | grep TO_CN   # global 应无 "ip daddr @TO_CN return"
cat /etc/gfc-client/nftables-bypass-ip.set                     # 含节点 IP + 控制面 IP

sh /usr/lib/gfc-client/deploy/check-vless.sh                   # 隧道必须通

# 流量：global 下国内站出口也应为节点 IP
curl -4 -sS https://api.ipify.org; echo
```

仅测 nft：可在盒子上用本地 API / LuCI 切 `global`，不必动控制平台。

### 6.3 切回 split 回归

```bash
# PATCH routing_scheme=split 或 PUT 本地 /api/policy/routing {"mode":"split"}
nft list chain inet gfc prerouting_mangle_route | grep TO_CN   # 应恢复 @TO_CN return
```

### 6.4 可选后续增强（未排期）

- global 切换前检查 `bypass_ip` 非空
- 将 Reality 握手目标 IP 纳入 bypass 自动解析
- Orchestrator 同步 `routing_mode` 到 SQLite（当前仅写 `routing-mode.json`；本地 settings 可能陈旧）

---

## 7. 踩过的坑 — 新会话不要再踩

### 7.1 架构 / 数据面

1. **不要用 main 表默认路由指向 gfctun**  
   与 `netifd` WAN 默认路由冲突，且偏离 `fwmark → table 2022` 架构；历史上与 `auto_route` 并存导致过环路。

2. **kernel-split 下 sing-box 不必按 global 改 route**  
   分流在 **nft**；TUN 内已是 `catch-all → proxy-prefer`。改 sing-box GeoIP 违反 `SINGBOX_ARCHITECTURE.md`。

3. **global 仍需 nft 例外规则**  
   私网、LAN、DNS 端口、bypass_ip、ext_const 都不能删；不是「不用 mark」就能简化。

4. **两条部署路径都要改**  
   - Ubuntu：`gen-nft-policy.py` → `lib-policy-routing.sh` → `gfc-routing.sh`  
   - ImmortalWrt：内联 `gfc-routing.sh`（不经过 gen-nft-policy）  
   只改一处会导致平台行为不一致。

5. **legacy `scheme_b` / `gfc_client_mangle` 不是生产路径**  
   曾有 `routing_mode` 支持但表名与 `NFT_ARCHITECTURE.md` 不一致；生产是 `inet gfc` + `render_architecture()`。

### 7.2 同步链

6. **控制面改 `routing_scheme` 以前不进 bundle**  
   现已通过 `routingScheme` 下发；改 routing 会 bump bundle version，agent 才会 `ApplyPayload`。

7. **`ApplyPayload` 顺序**  
   sing-box 渲染在写 `routing-mode.json` **之前**；对 kernel-split 无影响（sing-box 不读 mode）。nft 重载在 `postDataplaneRepair` → `gfc-routing start`，此时 json 已更新。

8. **bypass 依赖 bundle**  
   本次已加 `controlPlaneServers`；节点 IP 仍来自 `node.address`。缺 bypass → global 必断隧道。

### 7.3 规则与流程

9. **改 nft / sing-box / unbound 生成器**  
   工作区强制：先读架构文档 → 出差异表 → 等用户「确认修改」。本会话用户已确认 global 方案。

10. **DNS 与路由模式解耦**  
    用户明确：global 不改变 unbound 解析策略；不要把「IP 全局代理」做成「DNS 也全局」除非单独需求。

### 7.4 工具链

11. **Windows PowerShell 不支持 bash heredoc 写 commit message**  
    用 `git commit -m "title" -m "body"` 或多 `-m`。

12. **回滚标签在开发前已打**  
    `rollback/pre-global-routing-20260710`；新功能在 `731fee3`。

---

## 8. 关键文件索引

```
docs/NFT_ARCHITECTURE.md              # 含 split/global 规范
gfc-client/deploy/gen-nft-policy.py   # Ubuntu nft 生成
gfc-client/deploy/immortalwrt/gfc-routing.sh
gfc-client/deploy/lib-policy-routing.sh
gfc-client/internal/orchestrator/orchestrator.go
gfc-client/internal/payload/mode.go
gfc-platform/control-plane/api/app/client_config.py
/etc/gfc-client/routing-mode.json     # 运行时（盒端）
/var/lib/gfc-client/state/config_bundle.json
```

---

## 9. 相关会话决策一句话

> **全局模式 = kernel-split 不变 + nft 在 global 时去掉 `@TO_CN return` + bypass_ip 保隧道 + unbound DNS 分流不变 + 控制面 `routingScheme` 同步到盒端 `routing-mode.json`。**

---

*Handoff 生成时间：2026-07-10。基于 commit `731fee3`。*
