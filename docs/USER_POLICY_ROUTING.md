# GFC 用户策略路由与系统分流规则（设备 Web）

**Status:** 规格定稿。泛域名一期已打产品 tag **`v2.1.0`**（`gfc-client 2.1.0-r1`）；后续开发透明模式。改 nft 表/链/unbound 生成器前仍须「确认修改」+ 点名文件。  
**会话交接（下一会话入口）：** [`SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md`](SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md)  
**策略路由总交接（历史）：** [`SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md`](SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md)  
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

**泛域名拍板（2026-08-28，不得重开选型）：** 一层 `*`；通配**不含**顶点；嗅探 UDP/53 应答写 `usr_dom_*`；**接受首包竞态**（一期不上 nfqueue）。详见 §2.3。

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
| `domain` | `usr_dom_<id>` | 域名解析结果（动态，timeout）；store 存精确 FQDN 与一层通配 |

**禁止** 将用户成员写入系统 set。  
域名：store 存成员 → 精确名经 unbound `:53` 解析 A；`*.example.com` 由 DNS 嗅探学习 A → 写入 `usr_dom_<id>` → nft 匹配 `daddr`。AAAA 不写入（与 unbound `do-ip6: no` 一致）。

### 2.3 泛域名开发规范（飞塔同类 · 一期 · 强制）

本节是泛域名的**开发规范**。实现与本节冲突报 **bug**，不得改本节迁就代码。改匹配深度 / 顶点语义 / 挂钩方式须用户明确批准。

#### 2.3.1 产品意图

管理员在域名组填写 `*.linkedin.com`（不必手填 `platform.linkedin.com`）。LAN 客户端用浏览器打开站点时，页面若再查询子域，查询仍走现有 DNS 劫持 → unbound `:53`。网关从这次**真实 DNS 应答**学习 A 记录，写入该组 `usr_dom_*`，供用户 Override 按目的 IP 匹配。

**不是**对 `*.linkedin.com` 做一次递归枚举。**不是**解析每个网页/HTTPS 包。**不是**用 sing-box `domain_suffix` 做中外分流。

`*.linkedin.com` **盖不住** `static.licdn.com` 等其它后缀（飞塔同样如此）。首页与子域都要覆盖时，组成员写两行：`linkedin.com` + `*.linkedin.com`。

系统默认分流对非 CN 已进代理时，「整站进代理」可能看不出差异；本能力的主价值是 **Override**（例如整站强制直连，或源组 + 域名组组合）。

#### 2.3.2 已拍板（禁止重开）

| 项 | 取值 |
|----|------|
| 通配形态 | 仅最左一层 `*.example.com` |
| 顶点 | **不含**。`*.linkedin.com` 不匹配 `linkedin.com` |
| 多层子域 | **不匹配**。`*.linkedin.com` 不匹配 `a.b.linkedin.com` |
| 精确名 | 仅 QNAME 全等；**禁止**把精确名当任意深度后缀 |
| 挂钩 | 嗅探 UDP/53 应答（AF_PACKET + BPF）；**接受首包竞态** |
| 一期不做 | nfqueue；改 hijack 目标；改 unbound.conf；TCP/53；DoH/DoT；AAAA；拆 SNI/HTTPS |

#### 2.3.3 匹配算法（规范）

成员先规范化：小写、去尾点。

| 成员 | 命中 QNAME | 不命中 |
|------|------------|--------|
| `linkedin.com` | 仅 `linkedin.com` | `www.linkedin.com`、`platform.linkedin.com` |
| `*.linkedin.com` | 恰好一层：`platform.linkedin.com`、`www.linkedin.com` | 顶点；`a.b.linkedin.com`；`static.licdn.com` |

**合法通配：** `*` 仅允许最左标签；其后必须是 ≥2 个标签的 FQDN（`linkedin.com` 合法，`com` 非法）。

**非法：** `*`、`*.com`、`foo.*.com`、中缀 `*`。

试算 `probe_domain` 必须是**实际 QNAME**，不得填通配符。试算匹配必须与本节算法一致（精确 ≠ 后缀）。

代码锚点：`qnameMatchesMember` / `normalizeFQDN` / `normalizeProbeQName`（`gfc-client/internal/policyrouting/members.go`）。

#### 2.3.4 识别路径（规范）

```
浏览器查询 platform.linkedin.com（客户端自己发起，管理员不用手查）
  → nft inet gfc_dns_hijack redirect :53     （已有，不改）
  → unbound (gfc-unbound) :53                （已有，不改 conf）
  → 应答 UDP sport 53 回到客户端
  → gfc-api 嗅探该应答（QNAME + 同包 A，含 additional）
  → 一层命中 *.linkedin.com
  → nft add element inet gfc usr_dom_<id> { ip timeout <TTL> }
  → 后续 TCP/UDP 在 user overlay 按 ip daddr @usr_dom_* 走 Override
```

- 只处理 **DNS 报文**（UDP/53）。禁止为对本功能做全流量 DPI / SNI。
- 嗅探网卡：**lo** + 运行时 LAN；`proxy_mode=bypass` 时再加 WAN（客户 DNS 从 WAN 入向劫持）。**禁止只抓 lo**（会漏掉 LAN 客户查询）。
- 无「被启用策略引用的域名组」时不挂接口。
- 进程：`gfc-api` **进程级单例**（`mode=both` 不得开两份）。`gfc-agent` 不重复嗅探。
- BPF 过滤 UDP/53；禁止无过滤地 AF_PACKET 全量 IPv4（尤其 WAN）。

#### 2.3.5 喂数、TTL、落盘

| 成员类型 | apply | 运行时 |
|----------|-------|--------|
| 精确 FQDN | `LookupIP` → `127.0.0.1:53`（与 LAN 同一 unbound 分流） | 嗅探到该 QNAME 的应答可刷新 IP |
| `*.example.com` | **禁止** LookupIP 字面量 | 仅嗅探学习 |

- 只写入 **A**；忽略 AAAA（与 unbound `do-ip6: no` 一致）。
- nft timeout = DNS TTL，**下限 60s、上限 1h**（与 `usr_dom_*` 默认 timeout 对齐）。
- 同包 CNAME：用同一 DNS 报文内的 A（含 additional）。无 A 则本期可不追问。
- 学习条目写入 `/etc/gfc-client/policy-routing/domain-map.json` 的 `groups.<id>.learned[]`（`qname` / `pattern` / `ips` / `expires_at` / `source=dns-snoop`）。
- **apply / `inet gfc` 表重建：** flush `usr_dom_*` 后必须恢复 **精确解析 IP ∪ 未过期且仍匹配当前成员的 learned**。禁止只写 apply 瞬时 LookupIP 而冲掉嗅探结果。
- learned 在过期、或 QNAME 不再匹配当前组成员时丢弃。

#### 2.3.6 首包竞态（一期接受）

嗅探异步：DNS 应答照常交给客户端，随后才 `nft add`。第一条业务连接可能仍走系统默认分流；IP 入集后后续连接命中 Override。

- 策略与系统默认同向（例如国际本就进代理）时，现场往往看不出。
- 策略与系统默认相反（例如 LinkedIn 强制直连）时，**第一条可能仍进代理**。二期若用户要求「第一条必须准」，再单独立项 nfqueue（须 nft「确认修改」）。

#### 2.3.7 绝对禁止

- 用 MosDNS / sing-box DNS inbound / fake-ip 替代 unbound 服务 LAN `:53`
- 改 `gfc_dns_hijack` 目标端口或在 unbound 前再插一层 DNS 代理
- 改 unbound.conf（`log-replies` / dnstap 等）作为一期路径
- 用户域名 IP 写入 `TO_CN` / `bypass_ip` / `ext` / `ext_const`
- kernel-split 用 sing-box `domain_suffix` / `rule_set` 做中外分流
- 为试编本功能 bump 产品版本 / `PKG_RELEASE`（§1.5）
- 默认改为任意深度后缀或把顶点算进 `*.example.com`（除非用户改规格）

#### 2.3.8 实现锚点（代码已按本节落地，下一会话以差异表核对）

| 职责 | 路径 |
|------|------|
| 匹配 / 校验 | `gfc-client/internal/policyrouting/members.go` |
| apply 合并 learned | `domain_resolve.go`、`apply.go` |
| UDP/53 解析 | `dns_msg.go` |
| 嗅探单例 | `dns_snoop.go`；Linux AF_PACKET：`dns_snoop_linux.go` |
| `gfc-api` 启动 | `gfc-client/internal/api/server.go` → `StartDNSSnoop` |
| LuCI | `policy-route.js`、`system-split.js` |
| 落盘 | `groups.json` / `policies.json` / `domain-map.json` |

**不改：** `gfc-routing.sh` 表/链骨架、unbound 模板/生成器、sing-box 生成器、`NFT_ARCHITECTURE.md` / `UNBOUND_ARCHITECTURE.md`（除非补「不改」备注且用户要求）。

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
| `members[]` | 是 | IP/CIDR 或 FQDN（一行一个）；域名组允许 `*.example.com`（一层 `*`，不含顶点） |
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
- 域名时：解析 IP 列表、所属 `usr_dom_*`；试算填 **实际 QNAME**（如 `platform.linkedin.com`），不得填通配符；精确成员不再按任意深度后缀命中  
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
| GET | `domain-map` | 精确解析 + `learned` 嗅探快照（只读） |

- 写路径：**仅设备 Web**；控制面只读上报（若协议需要）。  
- `bypass_ip` 成员删除 API：**拒绝**（系统成员）。  

存储路径建议（实现可调整，须进固件文档）：  
`/etc/gfc-client/policy-routing/groups.json`、`policies.json`、`domain-map.json`。

---

## 7. 与数据面插入点（实现约束，须另批「确认修改」）

在不改表名/链名/hook/默认 mark 的前提下：

- 用户 Override 规则插入 **`prerouting_mangle_route`（及必要的 output 对称，若有）中、安全轨/`bypass_ip` 返回之后、系统默认 `TO_CN`/打标之前** 的固定注释锚点。  
- `proxy` 动作：复用现有 ct/meta mark `0x2023` 生命周期（一期）。  
- `direct` 动作：对该匹配 **return / 不打标**（与现直连语义一致）。  
- 新增 nft set 仅 `usr_*`；不得改名现有强制 set。  
- 域名组与 unbound 的接线不得用 MosDNS / sing-box DNS inbound 替代 LAN `:53`。  
- 泛域名一期：仅嗅探 UDP/53 应答写 `usr_dom_*`；不改表名/链/hook、不改 unbound.conf、不上 nfqueue。  

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
- [ ] `*.linkedin.com` 可保存；`platform.linkedin.com` 经嗅探进入 `usr_dom_*`；顶点与 `a.b.linkedin.com` 不因该通配命中  
- [ ] apply 不冲掉未过期的嗅探学习 IP  
- [ ] 试算 `platform.linkedin.com` 命中 `*.linkedin.com`；试算顶点 / 两层子域不命中  
- [ ] 学习 IP 不出现在 `TO_CN` / `bypass_ip` / `ext_const`  

---

## 9. 文档关系

| 文档 | 关系 |
|------|------|
| 本文 | 用户策略 / UI / 合成语义 / **泛域名开发规范 §2.3** **唯一产品真相** |
| `SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md` | 泛域名会话交接与下一会话开发入口 |
| `NFT_ARCHITECTURE.md` | 插入点与 mark；改链须架构评审 |
| `BYPASS_MODE.md` | 旁路入向；不另建旁路策略模型 |
| `UNBOUND_ARCHITECTURE.md` | 域名组解析落点 |
| `SINGBOX_ARCHITECTURE.md` | 一期不改 kernel-split 出站契约 |

---

## 10. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-31 | §2.3 升为开发规范（匹配算法、识别路径、禁止项、代码锚点）；交接改指向 08-31 |
| 2026-08-28 | 泛域名一期拍板：一层 `*`、通配不含顶点、UDP/53 嗅探写 `usr_dom_*`、接受首包竞态 |
| 2026-08-26 | 讨论冻结定稿：usr_*、Override、上移优先、仅源匹配、系统分流规则页、网关/旁路/透明同模型 |
