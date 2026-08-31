# 会话交接：用户策略路由 / 系统分流规则（2026-08-26）

> **后续（泛域名）：** [`SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md`](SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md) — 2026-08 已拍板一层 `*` 并落地代码；新会话从 08-31 文档进入，不要按下面「Agent 未开始」重开。  
> 写给**无本对话上下文**的新会话：按本文 + 权威规格开发。  
> **产品/UI/合成语义唯一真相：** [`docs/USER_POLICY_ROUTING.md`](USER_POLICY_ROUTING.md)  
> 数据面仍服从：[`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)、[`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)、[`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)、[`BYPASS_MODE.md`](BYPASS_MODE.md)  
> 对应 no-change 规则：`.cursor/rules/nft-no-change-without-approval.mdc` 等

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 需求讨论与产品拍板 | **已完成**（本会话） |
| 规格定稿 | **已完成** → `docs/USER_POLICY_ROUTING.md` |
| Agent API / 存盘 / Apply | **未开始** |
| LuCI「策略路由」页（现为占位） | **未按新规格实现**（仅 planned 文案） |
| 新页「系统分流规则」 | **未开始**（菜单项尚无） |
| nft 用户插入点 / `usr_*` set 生成器 | **未开始**；**须「确认修改」+ 点名文件** |
| unbound 域名组 → `usr_dom_*` | **未开始**；**须批准** |
| sing-box kernel-split | **本期不改**（`action=proxy` 复用现有 `0x2023→gfctun`） |
| 产品版本 / `PKG_RELEASE` | **试编/排错不升号**（§1.5）；正式交付进固件再定 |

**禁止**把本需求当成「未讨论」重开架构选型；有冲突以 `USER_POLICY_ROUTING.md` 为准，改规格须用户明确批准。

---

## 1. 本会话讨论了什么（摘要）

### 1.1 问题

系统默认数据面（nft / ip rule / 中外分流）多为生成器写死；现场需要：

- 指定源 IP / 目的 IP / 域名 → 直连或进代理  
- 自定义 IP 列表、策略打标与路由  
- 与系统规则**并存**，且不能被系统 reload 冲掉用户配置  

### 1.2 否决/纠正的误解

| 说法 | 结论 |
|------|------|
| 「系统先启用、用户后启用」= 两次独立 apply 碰运气 | **改为一次合成（merge）**；链内 first-match + UI 优先级 |
| 用户 IP/域名写入 `TO_CN` / `bypass_ip` / `ext_const` | **禁止**；用自建 `usr_src_*` / `usr_dst_*` / `usr_dom_*` |
| Web 任意改 nft/ip rule/route 原文 | **一期不做**；L0 只读；L1 用 Override；系统页只读 |
| 应用名/skuid 分流 | **非 P0**；与架构禁 skuid 替代分流一致 |
| 多线路 `action=线路A/B` | **非一期**；一期仅 `direct` \| `proxy` |
| 旁路另做一套策略模型 | **否**；网关/旁路/未来透明 **同一模型**，只变入向 |

### 1.3 已拍板决议（与规格 §0 一致）

1. 允许用户覆盖「国内→代理 / 国际→直连」——**用户显式优先于系统默认分流**  
2. `bypass_ip` 系统成员（含 POP 等）**默认拒绝删 / 改成进代理**  
3. **Override 为主**（不就地改生成器规则原文）  
4. 控制面刷新 POP → **合并** `bypass_ip`；CN 库更新 → **合并** `TO_CN`；**不冲**用户组与 Override  
5. 用户对象进 **自建 set**  
6. UI：**列表上移 = 更高优先级**，底层再映射  
7. **允许仅源匹配、目的任意**（少主机强制出口），须 `danger_ack`  
8. `gateway` / `bypass` / 未来 `transparent` 同模型  

「控制面刷新中国 IP / bypass」澄清：  

- **bypass_ip**：控制面 Bundle（转发节点 POP、控制器等）→ 合并  
- **TO_CN**：CN 库同步（未必每次经控制面）→ 合并集合；Override 保留  

---

## 2. 权威文档与现有代码锚点

| 文档/代码 | 用途 |
|-----------|------|
| [`docs/USER_POLICY_ROUTING.md`](USER_POLICY_ROUTING.md) | **开发必读**：分层、字段、UI、API 草约、验收、插入点约束 |
| 本文 | 会话交接、开发顺序、禁止重开项 |
| LuCI 菜单 | `luci-app-gfc` → `admin/gfc/config/*`（业务配置） |
| 策略路由占位 | `.../view/gfc/policy-route.js`（现「功能预留中」） |
| 菜单 JSON | `.../menu.d/luci-app-gfc.json`（`policy-route` order 40；其后为 `settings` 设备运行模式） |
| 静态路由参考 | `.../view/gfc/routing.js`（API `127.0.0.1:8080/api/v1`） |
| 旁路/模式 | `.../view/gfc/settings.js`；`docs/BYPASS_MODE.md` |

**新页名称（已定）：**「系统分流规则」（建议 menu path 如 `gfc/system-split` / `admin/gfc/config/system-split`，实现时选定并写入菜单）。

---

## 3. 目标架构（给实现者的速查）

```
设备 Web 权威                    控制面 / CN 库
groups + policies                 bypass_ip / TO_CN 合并
        \                         /
         \                       /
          ▼                     ▼
     一次合成 Effective Policy
     裁决：安全轨 > 用户 Override（上移优先）> 系统默认分流
     proxy → 现有 0x2023 → table 2022 → gfctun
     direct → 不打标 / return（与现直连一致）
```

- **冲突展示**：规则行状态 + **冲突试算**（非单独菜单页）  
- **主写入口**：策略路由（组 + Override + 试算）  
- **系统只读入口**：系统分流规则  

存储建议（规格内，可微调但须文档同步）：  
`/etc/gfc-client/policy-routing/groups.json`、`policies.json`。

API 草约前缀：`/api/v1/policy-routing/`（groups / policies / apply / probe / system-rules）。

---

## 4. 下一会话建议开发顺序

> 严格按 `docs/USER_POLICY_ROUTING.md`；只改点名文件；数据面改前先差异表，等「确认修改」。

### 阶段 A — 无数据面变更（可先做）

1. Agent：groups/policies 存盘 CRUD + 校验（仅源、互斥目的/域名、空匹配拒绝）  
2. `POST probe`：纯逻辑试算（可先 mock 系统层命中）  
3. LuCI：重做「策略路由」页（组 + 规则表 + 上移下移 + danger_ack + 试算）  
4. LuCI：新增「系统分流规则」只读壳（摘要 + 跳转添加覆盖）  

### 阶段 B — 须用户「确认修改」后

1. 输出 **规范 vs 当前生成器** 差异表（插入点、`usr_*` set）  
2. nft 生成器：用户段插入锚点；sync `usr_src/dst`  
3. unbound/域名组 → `usr_dom_*`（禁止 MosDNS 替代 LAN DNS）  
4. apply 事务 + 失败回滚；与现有 dataplane apply/rollback 对齐  

### 阶段 C — 联调验收

按 `USER_POLICY_ROUTING.md` §8 清单；网关 + 旁路各测仅源强制、覆盖 TO_CN、bypass 安全轨、POP 合并不丢用户策略。

**版本：** 未宣布发版则 **不** bump 产品 `vX.Y.Z` / 不切 tag；进 OEM 镜像时再议 `PKG_RELEASE`（§1.5）。

---

## 5. 新会话开场建议口令

```
读 docs/SESSION_HANDOFF_2026-08-26_USER_POLICY_ROUTING.md
与 docs/USER_POLICY_ROUTING.md。
按规格实现；只改我点名的文件。
涉及 nft/unbound/sing-box 先给规范 vs 实现差异表，我确认后再写代码。
试编排错不升产品版本号。
```

---

## 6. 禁止再踩 / 禁止重开

| 项 | 要求 |
|----|------|
| 两套 nft 引擎先后覆盖 | 禁止；必须一次合成 |
| 用户成员写入系统 set | 禁止 |
| 改 L0 表链 hook / 默认 mark | 禁止（无架构评审） |
| 旁路关掉 `0x2023→2022→gfctun` | 禁止（已是 bug） |
| 用 MosDNS / sing-box DNS 替代 unbound 服务 LAN | 禁止 |
| 一期多线路 mark / 应用分流 / Detach 原文编辑 | 不做 |
| 未确认修改就改生成器 | 禁止 |
| 用实现倒逼改规格 | 禁止；报 bug |

---

## 7. 本会话未交付物

- 无生成器代码、无新 API 实现、无新 LuCI 功能页（除既有占位）  
- 未 commit（除非用户另嘱）；规格文件路径：`docs/USER_POLICY_ROUTING.md` + 本文  

---

## 8. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-26 | 首版交接：讨论冻结 → 规格定稿 → 待开发 |
