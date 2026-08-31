# 会话交接：泛域名 / 飞塔同类 FQDN（2026-08-31）

> 写给**无本对话上下文**的新会话：按本文开发、验收、修 bug。  
> **产品 / 匹配 / 嗅探唯一真相：** [`docs/USER_POLICY_ROUTING.md`](USER_POLICY_ROUTING.md) **§2.3**  
> 用户策略总规格（组 / Override / UI）：同文件其余章节  
> 数据面骨架：[`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)、[`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)、[`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)  
> Cursor：`.cursor/rules/wildcard-fqdn.mdc`；nft / unbound / sing-box 仍走各自 no-change-without-approval  
> 历史总交接（策略路由从 0 到有）：[`SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md`](SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md)（其中「Agent 未开始」已过时，以本文为准）

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 需求讨论与拍板 | **已完成**（2026-08-28） |
| 规格 / 开发规范 | **已完成** → `USER_POLICY_ROUTING.md` §2.3 |
| Agent 匹配 / apply 合并 learned / 嗅探代码 | **已写并打 tag `v2.1.0`** |
| LuCI 文案与 learned 展示 | **已写** |
| nft 表/链/hook、unbound.conf、sing-box | **本期不改**（已拍板） |
| 产品版本 / `PKG_RELEASE` | **`v2.1.0` / `gfc-client 2.1.0-r1`**（Minor；后续透明模式另开） |

**禁止**把「一层 * / 顶点 / 嗅探 vs nfqueue」当未决重开。要改语义须用户明确改规格。

---

## 1. 业务需求（已拍板）

现场要飞塔那种用法：域名组填 `*.linkedin.com`，不必手填 `platform.linkedin.com`。用户打开 `linkedin.com` 后，浏览器若再查子域，盒子从这次 DNS 学习 IP，再走用户策略路由（直连或进代理）。

| 拍板 | 取值 | 不要理解成 |
|------|------|------------|
| 一层 `*` | `platform.linkedin.com` 命中；`a.b.linkedin.com` 不命中 | 任意深度后缀 |
| 通配不含顶点 | `linkedin.com` 须单独一行精确成员 | `*.linkedin.com` 自动含首页 |
| 嗅探、接受首包 | AF_PACKET 看 UDP/53 应答 | 拆每个网页包；一期 nfqueue |
| 只认传统 DNS | 现有 hijack → unbound `:53` | DoH/DoT、TCP/53 一期 |

其它后缀（`static.licdn.com`）**不会**被 `*.linkedin.com` 覆盖，须另加成员。CDN 共用 IP 是 DNS→IP 对象的固有误伤，与飞塔相同。

---

## 2. 规范 vs 实现（下一会话先做这件事）

权威：§2.3。代码在 `gfc-client/internal/policyrouting/`。

| 规范项 | 实现位置 | 下一会话 |
|--------|----------|----------|
| 一层 *、不含顶点、精确非后缀 | `members.go` `qnameMatchesMember` | 对照 §2.3.3；单测已有，**须在构建机跑** |
| 通配 apply 不 LookupIP | `domain_resolve.go` `buildDomainMap` | 核对 |
| flush 后合并 learned | `apply.go` + `keepLearned` | 核对；回归「保存策略不丢子域 IP」 |
| UDP/53 应答解析 | `dns_msg.go` | 核对 CNAME/additional A |
| Linux 嗅探 | `dns_snoop_linux.go`（lo+LAN；bypass+WAN；BPF） | **设备上确认能看见 LAN DNS** |
| 单例启动 | `api/server.go` `StartDNSSnoop` | 确认只在 `gfc-api` |
| LuCI | `policy-route.js` / `system-split.js` | 文案与 learned 行 |

发现与 §2.3 不一致：**报 bug 后按规格改代码**，不得改规格迁就。涉及 nft 生成器 / unbound 生成器仍须「确认修改」。

---

## 3. 下一会话开发顺序

> 严格按 `USER_POLICY_ROUTING.md` §2.3；只改点名文件。  
> 试编排错不升产品号。

### 阶段 0 — 只读核对（先做）

1. 读本文 + §2.3 + `.cursor/rules/wildcard-fqdn.mdc`  
2. 输出 **§2.3 vs 当前代码** 差异表（有则列文件）  
3. 无差异则进入阶段 1；有架构级差异先停，等用户确认

### 阶段 1 — 构建机验证（无数据面生成器变更）

```bash
export PATH=/usr/local/go/bin:$PATH
cd /opt/gfc/sip-proxy/gfc-client
go test ./internal/policyrouting/
```

Windows 开发机可能没有 `go`；以构建机为准。

### 阶段 2 — 设备联调（需求开发的验收主体）

1. 域名组：`linkedin.com` + `*.linkedin.com`（或用户指定站）  
2. Override：按现场意图 `direct` 或 `proxy`；勾选 `danger_ack`  
3. 保存并应用  
4. LAN 客户端用**普通 DNS**（关 Chrome 安全 DNS）访问该站  
5. 断言：
   - `GET /api/v1/policy-routing/domain-map` 的 `learned` 出现 `platform.…` 一类一层子域  
   - `nft list set inet gfc usr_dom_<id>` 含对应 A  
   - 顶点 / 两层子域不因通配入集  
   - 再点一次「保存并应用」，learned IP **还在**  
6. 旁路模式：客户源 ∈ `customer_hosts` 时 WAN 侧 DNS 也能学习  

失败则按 §2.3 修 Agent（嗅探网卡、BPF、sport=53、单例）；**不要**为此改 unbound 监听或 hijack 端口。

### 阶段 3 — 仅当用户点名且确认后

- 修 LuCI 展示 / 试算文案  
- 修 apply 合并 bug  
- **不要**主动做 nfqueue、TCP/53、DoH、任意深度 `*`  
- 进 OEM 镜像：用户宣布发版后再议 `PKG_RELEASE`（§1.5）

---

## 4. 代码与文档锚点

| 路径 | 用途 |
|------|------|
| `docs/USER_POLICY_ROUTING.md` §2.3 | **开发规范** |
| 本文 | 完成态、验收、禁止重开 |
| `.cursor/rules/wildcard-fqdn.mdc` | AI 强制约束 |
| `gfc-client/internal/policyrouting/*` | 匹配 / map / 嗅探 |
| `gfc-client/internal/api/server.go` | 启动嗅探 |
| `luci-app-gfc/.../view/gfc/policy-route.js` | 策略路由 UI |
| `luci-app-gfc/.../view/gfc/system-split.js` | 映射只读页 |

存储：`/etc/gfc-client/policy-routing/{groups,policies,domain-map}.json`。

---

## 5. 新会话开场建议口令

```
读 docs/SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md
与 docs/USER_POLICY_ROUTING.md §2.3。
按规格核对实现、跑 go test、做设备联调；只改我点名的文件。
nft/unbound/sing-box 生成器改前先差异表，我确认后再写。
试编排错不升产品版本号。
不要重开一层 * / 顶点 / nfqueue 选型。
```

---

## 6. 禁止再踩 / 禁止重开

| 项 | 要求 |
|----|------|
| 一层 * vs 任意子域 | 已拍板一层；禁止擅自改成后缀树 |
| 顶点计入 `*.example.com` | 已拍板不含；首页请加精确成员 |
| 首包竞态 | 一期接受嗅探；禁止未批准上 nfqueue |
| 解析每个上网包 / SNI | 禁止 |
| 只抓 lo | 禁止（漏 LAN） |
| MosDNS / sing-box DNS 替代 unbound | 禁止 |
| 学习 IP 进系统 set | 禁止 |
| 用实现改 §2.3 | 禁止；报 bug |
| 未宣布发版就 bump / 切 tag | 禁止 |

---

## 7. 本会话交付物

- 规格：`docs/USER_POLICY_ROUTING.md` §2.3 开发规范全文  
- 规则：`.cursor/rules/wildcard-fqdn.mdc`  
- 本文（下一会话入口）  
- 产品 tag **`v2.1.0`** / `gfc-client 2.1.0-r1`（泛域名一期收口）

---

## 8. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-31 | 产品 tag `v2.1.0`：泛域名一期收口，后续透明模式另开 |
| 2026-08-31 | 规格升格为 §2.3 开发规范；本交接作为下一会话开发/验收入口 |
| 2026-08-28 | 拍板 + Agent/LuCI 实现（设备未验） |
