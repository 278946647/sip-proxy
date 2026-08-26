# GFC 用户策略路由与系统分流规则（设备 Web）

**Status:** 规格定稿（讨论冻结）；**实现未开始**。改 nft / unbound / 生成器前仍须「确认修改」+ 点名文件。  
**会话交接（下一会话入口）：** [`SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md`](SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md)  
**权威 nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)（表/链/hook/默认 mark 不变；本能力为规定插入点上的 User Overlay）  
**权威 DNS：** [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)（LAN DNS 仍为 unbound；域名组结果写入用户动态 set）  
**权威 sing-box：** [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)（kernel-split 契约不因本能力改 `auto_route` / `route.final`）  
**旁路：** [`BYPASS_MODE.md`](BYPASS_MODE.md)（入向条件不同；策略模型相同）

若实现与本文冲突，报 **bug**，不得用实现迁就后改本文掩盖。

---

## 0. 合理性确认（已拍板）

| # | 决议 | 科学性 |
|---|------|--------|
| 1 | 用户可覆盖「国内→代理 / 国际→直连」；**用户显式策略优先于系统默认分流** | 现场例外是企业网关刚需；用 Override 表达，不污染系统 IP 库 |
| 2 | `bypass_ip` 系统成员 **默认拒绝删除/改成进代理** | 保节点/控制器/握手可达，避免自锁 |
| 3 | **Override 为主**；不就地改生成器 nft 原文 | 可审计、可升级合并、可回滚 |
| 4 | 控制面/库更新：**合并** `bypass_ip`（含 POP）与 `TO_CN`；**不冲**用户组与 Override | 双权威各管各的集合 |
| 5 | 用户 IP/域名进 **自建 `usr_*` set**，禁止写入 `TO_CN` / `bypass_ip` / `ext_const` | 语义隔离 |
| 6 | UI：**列表上移 = 更高优先级**；底层再映射 pref/链序 | 降低填错 |
| 7 | **允许仅源匹配、目的任意**（单机/少主机强制出口） | 合法；须高危确认 |
| 8 | `gateway` / `bypass` / 未来 `transparent` **同一策略模型** | 只变入向匹配，不变裁决 |

**一期动作空间：** `direct`（WAN 直连）| `proxy`（打标进默认 `0x2023 → 2022 → gfctun`）。多线路出站不在本期字段内。

---

## 1. 分层与唯一运行态

```
L0  Architecture Skeleton   表/链/hook/默认 mark/packet flow（Web 不可改）
L1  System Policy           生成器：TO_CN、bypass_ip、ext_const、默认分类、ip rule 骨架
L2  User Policy             设备 Web：usr_* 组 + Override 规则
        │
        ▼ 一次合成（merge），禁止「两套引擎先后碰运气」
Effective Policy
```

- **并存** = 两个配置源，**一份**生效规则集。  
- **先后** = 合成顺序固定：L0 → L1 底盘与安全轨 → L2（按 UI 优先级）→ L1 默认分流收尾。  
- **不是** 后一次 `nft -f` 覆盖前一次。

### 1.1 裁决顺序（高 → 低）

1. **安全轨（Safety Rail）** — 不可被用户关掉（本期）：`bypass_ip` 目的、本机/广播/组播、SSH 212 等架构已有返回  
2. **用户 Override** — UI 列表自上而下（上 = 更高优先级）  
3. **系统默认分流** — `TO_CN` 直连、`ext_const`/`ext` 进代理、其余按现网关逻辑  

同优先级、动作相反 → **拒绝保存**（强制用户调整顺序或合并），禁止静默 Last-write-wins。

---

## 2. 集合模型

### 2.1 系统 set（只读 / 合并更新）

| Set | 写者 | 用户 Web |
|-----|------|----------|
| `TO_CN` | CN 库同步等 | 只读浏览；可「添加覆盖」跳转策略路由 |
| `bypass_ip` | 控制面 Bundle（含转发节点 POP 等）**合并 upsert** | 系统成员不可删、不可改为 `proxy` |
| `ext_const` | 生成器 | 只读 |
| `ext` | 系统动态国际 | 只读 |
| `customer_hosts` | 设备运行模式（旁路） | **不在**策略路由里当动作 set |

### 2.2 用户 set（设备 Web 权威）

| 逻辑 kind | nft 名（实现约定） | 内容 |
|-----------|-------------------|------|
| `src_cidr` | `usr_src_<id>` | 源 IP/CIDR |
| `dst_cidr` | `usr_dst_<id>` | 目的 IP/CIDR |
| `domain` | `usr_dom_<id>` | 域名解析结果（动态，建议 timeout）；域名列表存 store |

**禁止** 将用户成员写入系统 set。  
域名：store 存 FQDN → DNS 路径将 A/AAAA 写入 `usr_dom_<id>` → nft 匹配 `daddr`。

---

## 3. 开发逻辑（Apply 流水线）

```
Store (groups + policies)     Control plane / CN sync
         │                              │
         ▼                              ▼
   sync usr_* sets              merge TO_CN / bypass_ip
         │
         ▼
   合成 nft：安全轨 → 用户规则(UI序) → 系统默认分类
         │
         ▼
   策略路由骨架保持 0x2023 → 2022 → gfctun（用户 proxy 动作复用此 mark，一期）
         │
         ▼
   validate → apply → 探针；失败回滚
```

### 3.1 仅源匹配

- `match_src` 有组，`match_dst` 空 = **该源访问任意目的** 走 `action`。  
- 仍受安全轨约束（目的 ∈ `bypass_ip` → 不得进代理）。  
- 保存须 `danger_ack`（文案见 §5.3）。

### 3.2 优先级映射

- UI：拖拽/上移下移；**第一行 = 最高用户优先级**。  
- Store：保存有序数组 `policies[]`；或显式 `rank`（0 = 最高）。  
- 生成器：映射到链内用户段规则顺序（先匹配先胜）；**不**让用户手填 `ip rule pref`。  
- 系统 `ip rule` pref 段与用户段隔离（实现时登记；用户不得占用系统 pref）。

### 3.3 模式（gateway / bypass / transparent）

- 同一 `policies[]` / `groups[]`。  
- 入向是否进入分类链：遵循 `NFT_ARCHITECTURE` + `BYPASS_MODE`（及未来透明）。  
- 试算 API 必须返回：`ingress_eligible` + 人话原因（例如旁路源不在 `customer_hosts`）。

### 3.4 控制面合并

- POP / 基础设施 IP 变化 → **合并** `bypass_ip`。  
- 不删除、不改写任何 `usr_*` 与 Override。  
- CN 库更新 → 合并 `TO_CN`；已有「CN→proxy」Override 继续优先生效。

### 3.5 非目标（本期禁止）

- Web 编辑 L0（改表名/链名/hook/默认 mark 常量）  
- 自由 nft / 任意 `ip rule` / 任意 `ip route` 文本  
- skuid / 应用名分流  
- 多 mark 多线路（`action` 指定线路 A/B）  
- Detach 编辑系统原文（可列为二期）  
- `transparent` 未开放前不得在 UI 启用该模式（与 `BYPASS_MODE` 一致）

---

## 4. UI 信息架构

**菜单位置：** `GFC 终端网关` → `业务配置`

| 标签 | 角色 |
|------|------|
| 静态路由 | 主机/网段静态路由（含 gfctun 出口）；**不做**源策略 Override |
| 代理出站选择 | TUN 内出站；与「是否进 TUN」分离 |
| DNS 与分流 | unbound / 分流上游；域名组与解析可深链 |
| **策略路由** | **L2 主战场**：组 + Override + 冲突试算 |
| **系统 nft 规则**（原「系统分流规则」） | L1/L0 **只读** + 系统集合浏览 + 域名→IP 映射 + 试算 +「添加覆盖」跳转 |
| 设备运行模式 | `proxy_mode`、旁路 `customer_hosts` |

冲突矩阵 **不** 单独占菜单；能力挂在「策略路由」（主）与「系统分流规则」（辅）。

---

## 5. UI 规格定稿

### 5.1 策略路由页布局

1. **冲突试算**（顶）  
2. **地址组 / 域名组**  
3. **策略规则（Override）** 表 + 上移/下移 + 保存并应用  

### 5.2 地址组 / 域名组字段

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | 系统生成 | 稳定；改名不改 id |
| `name` | 是 | 显示名 |
| `kind` | 是 | `src_cidr` \| `dst_cidr` \| `domain` |
| `members[]` | 是 | IP/CIDR 或 FQDN（一行一个） |
| `description` | 否 | |
| `ref_count` | 只读 | 被引用数；>0 删除须拦截或确认解绑 |

### 5.3 策略规则字段

| 字段 | 必填 | 说明 |
|------|------|------|
| `id` | 系统生成 | 展示为 Override#… |
| `enabled` | 是 | 默认 true |
| `name` | 是 | |
| `rank` / 列表序 | 是 | **上移 = 更高优先级**；不选手填裸 pref |
| `match_src_group_id` | 否 | 空 = 任意源 |
| `match_dst_group_id` | 条件 | `dst_cidr` 组；与域名组互斥 |
| `match_domain_group_id` | 条件 | 与目的组互斥 |
| `action` | 是 | `direct` \| `proxy` |
| `overrides_system` | 只读 | 保存/试算时计算 |
| `danger_ack` | 条件 | 见下 |
| `notes` | 否 | |

**匹配合法性：**

| 源 | 目的 | 允许 | 确认 |
|----|------|------|------|
| 有 | 目的组或域名组 | ✅ | 若与系统默认相反 → `danger_ack` |
| 有 | 空（任意目的） | ✅ **仅源** | **必须** `danger_ack` |
| 空 | 有 | ✅ | 若与系统默认相反 → `danger_ack` |
| 空 | 空 | ❌ 拒绝 | |

**`danger_ack` 文案（须用户勾选）：**

- 仅源：`该源访问任意目的将强制 {直连|进代理}，可能影响该主机全部上网路径。`  
- 覆盖系统默认：`此规则将覆盖系统默认分流（例如国内走代理或国际走直连）。`  

**列表列：** `启用 | 优先级序 | 名称 | 源组 | 目的/域名组 | 动作 | 状态 | 原因 | 操作(上移/下移/编辑/删)`

**状态枚举：** `active` | `shadowed` | `blocked_by_safety`（被安全轨拒绝生效）

### 5.4 冲突试算

**输入：** `probe_src`（可选）、`probe_dst` 或 `probe_domain`（必填其一）  

**输出：**

- 命中链（安全轨 → Override 序 → 系统默认）  
- `winner_id` / `winner_layer`  
- `action`  
- `reason`（人话）  
- 域名时：解析 IP 列表、所属 `usr_dom_*`  
- `ingress_eligible` + 当前 `proxy_mode` 说明  
- 目的 ∈ `bypass_ip` 时明确安全轨结果  

### 5.5 系统分流规则页

1. 生效摘要：模式、`0x2023→2022→gfctun`、安全轨健康  
2. 系统集合只读：`TO_CN` / `bypass_ip` / `ext_const`（及旁路提示 `customer_hosts` 在运行模式页）  
3. 系统默认规则列表 +「已被 Override#n 覆盖」  
4. `ip rule` / table `2022` 只读摘要  
5. 按钮：**添加覆盖** → 跳转策略路由并预填  
6. 同款冲突试算（只读排障）  
7. **一期不提供** 原文编辑 / Detach  

### 5.6 与静态路由 / DNS / 运行模式边界

- 静态路由：补路由，不写 Override。  
- DNS：域名如何解析；策略路由引用域名组 id。  
- 运行模式：只切 `proxy_mode` 与 `customer_hosts`。  

---

## 6. API 草约（设备 Agent，一期）

前缀建议：`/api/v1/policy-routing/`（最终以实现为准，本表定语义）

| 方法 | 路径 | 语义 |
|------|------|------|
| GET/PUT | `groups` | 地址组/域名组 |
| GET/PUT | `policies` | Override 有序表 |
| POST | `apply` | 合成并应用；返回冲突/校验错误 |
| POST | `probe` | 冲突试算 |
| GET | `system-rules` | 系统分流规则页只读模型 |
| GET | `effective` | 可选：生效摘要 |

- 写路径：**仅设备 Web**；控制面只读上报（若协议需要）。  
- `bypass_ip` 成员删除 API：**拒绝**（系统成员）。  

存储路径建议（实现可调整，须进固件文档）：  
`/etc/gfc-client/policy-routing/groups.json`、`policies.json`。

---

## 7. 与数据面插入点（实现约束，须另批「确认修改」）

在不改表名/链名/hook/默认 mark 的前提下：

- 用户 Override 规则插入 **`prerouting_mangle_route`（及必要的 output 对称，若有）中、安全轨/`bypass_ip` 返回之后、系统默认 `TO_CN`/打标之前** 的固定注释锚点。  
- `proxy` 动作：复用现有 ct/meta mark `0x2023` 生命周期（一期）。  
- `direct` 动作：对该匹配 **return / 不打标**（与现直连语义一致）。  
- 新增 nft set 仅 `usr_*`；不得改名现有强制 set。  
- 域名组与 unbound 的接线不得用 MosDNS / sing-box DNS inbound 替代 LAN `:53`。  

**未获用户「确认修改」+ 点名生成器文件前，禁止改生成器代码。**

---

## 8. 验收要点（实现后）

- [ ] 用户组元素不出现在 `TO_CN` / `bypass_ip` / `ext_const`  
- [ ] 仅源规则：指定 LAN 主机强制 `proxy` 或 `direct` 生效；目的为节点 IP 时仍被安全轨直连  
- [ ] 上移后试算获胜方变化与列表一致  
- [ ] 覆盖 `TO_CN`→`proxy` 须确认；生效后 CN 库合并不丢 Override  
- [ ] POP 合并进 `bypass_ip` 不丢用户策略  
- [ ] 网关与旁路同一 policies；旁路非 `customer_hosts` 源试算显示不可入向  
- [ ] 系统分流规则页只读；策略路由可写  
- [ ] apply 失败可回滚；不破坏 `0x2023→2022→gfctun` 骨架  

---

## 9. 文档关系

| 文档 | 关系 |
|------|------|
| 本文 | 用户策略 / UI / 合成语义 **唯一产品真相** |
| `NFT_ARCHITECTURE.md` | 插入点与 mark；改链须架构评审 |
| `BYPASS_MODE.md` | 旁路入向；不另建旁路策略模型 |
| `UNBOUND_ARCHITECTURE.md` | 域名组解析落点 |
| `SINGBOX_ARCHITECTURE.md` | 一期不改 kernel-split 出站契约 |

---

## 10. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-26 | 讨论冻结定稿：usr_*、Override、上移优先、仅源匹配、系统分流规则页、网关/旁路/透明同模型 |
