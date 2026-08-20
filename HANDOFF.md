# GFC 会话交接（HANDOFF）

> 写给**完全没有上下文**的新对话。  
> 最后更新：**2026-08-20**  
> 仓库：`sip-proxy`（`gfc-platform/` 控制平台 + `gfc-client/` ImmortalWrt 客户端）  
> **当前主线：旁路模式（bypass）规范已批准，代码未实现。**

---

## 0. 新会话 30 秒开场

```
读 HANDOFF.md + docs/BYPASS_MODE_DEV_PLAN.md；
严格按 docs/NFT_ARCHITECTURE.md §9.3 Option B；
旁路实现先给规范 vs 实现差异表，等我「确认修改」后再改我点名的文件；
模式切换仅设备 Web；@customer_hosts 本地 Web 录入；超时未确认回滚；
回滚基线 tag：v1.1.9。
```

| 文档 | 用途 |
|------|------|
| [`docs/NFT_ARCHITECTURE.md`](docs/NFT_ARCHITECTURE.md) §9.1–§9.3 | 旁路 nft **唯一真相**（Option B） |
| [`docs/BYPASS_MODE_DEV_PLAN.md`](docs/BYPASS_MODE_DEV_PLAN.md) | 开发阶段 / 不做清单 |
| [`docs/VERSION_AND_RELEASE.md`](docs/VERSION_AND_RELEASE.md) | 发版；试编排错不升号 |
| [`gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md`](gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md) | **仅当任务是固件 OEM 构建时** |

数据面改代码前：nft / unbound / sing-box 均须「差异表 → 用户确认修改」。

---

## 1. 本会话做了什么任务

| 主题 | 内容 |
|------|------|
| 旁路模式架构讨论 | 相对网关：用户流量从 WAN 进；本机 OUTPUT 利旧；防环；DNS；模式切换 |
| 打标策略选型 | 否决「WAN 全量新连接 mark」（方案 A）；采纳 **方案 B**（`saddr @customer_hosts`） |
| DNS | 确认旁路仍要劫持；**不能只沿用 LAN**；须 WAN+customer 四条 |
| 产品契约 | 仅设备 Web 切 `proxy_mode`；控制面只读；超时确认回滚；LAN 小网关保留 |
| 存档发版 | 产品 **v1.1.9** annotated tag（实现前基线） |
| 规范入库 | `NFT_ARCHITECTURE.md` §9.3 + `BYPASS_MODE_DEV_PLAN.md` + 本 HANDOFF |

**未做：** 任何生成器/`gfc-routing.sh`/LuCI 旁路实现代码。

---

## 2. 已经完成了什么

### 2.1 决议（已写入规范）

1. **Option B**：WAN 仅当 `ip saddr @customer_hosts` 才 ct mark / 分类 / DNS 劫持。  
2. **`@customer_hosts`**：设备 Web 录入（开局权威）；≠ 控制面下发；≠ 简单等于 WAN 掩码（公网 IP 场景尤甚）。  
3. **DNS**：LAN 两条保留 + WAN customer local-return×2 + redirect×2。  
4. **NAT**：客户不做 WAN SNAT；管理 LAN 受限 masquerade（小网关）。  
5. **小网关**：插管理 LAN 的笔记本可把 GFC 当默认网关，国内直连 + 跨境进 TUN（便于开局自测）。  
6. **模式切换**：仅设备 Web 写入 → 校验 → 单一编排 apply → 健康检查 → **超时未确认回滚**。  
7. **策略路由**：旁路必须开 `0x2023→2022→gfctun`（与旧 `GATEWAY_CORE.md`「bypass 关 mangle」相反，以 NFT 规范为准）。

### 2.2 仓库状态（实现缺口）

| 组件 | 相对 §9.3 |
|------|-----------|
| `gfc-routing.sh` / `gen-nft-policy.py` | 仅网关 `iif LAN` |
| `lib-unbound-nft.sh` | 仅 LAN DNS hijack |
| NAT apply | 全 WAN masquerade |
| `lib-policy-routing.sh` | `bypass` 时 **关闭** 策略路由 ← bug vs 新规范 |
| LuCI settings | 「旁路模式（待开发）」 |
| 控制面 `proxy_mode` 字段 | 仍可下发；产品决议实现后应改为只读/忽略写入 |

### 2.3 版本存档

- 产品当前：`v1.1.9`（见 `docs/releases/VERSION_MATRIX.json`）  
- `gfc_client` 仍钉 `1.1.0-r23`（本版无固件内容变更，**未** bump `PKG_RELEASE`）  
- 找回：`git fetch --tags && git checkout v1.1.9`

---

## 3. 当前卡在哪

1. **规范已批、代码未写** — 下一步是按 `BYPASS_MODE_DEV_PLAN.md` P1/P2/P3，且每次改 nft 相关文件前要「确认修改」。  
2. **`GATEWAY_CORE.md` / 旧脚本语义** 仍写「bypass 关策略路由」，与新规范冲突；实现时以 `NFT_ARCHITECTURE.md` 为准，顺带改过时文档。  
3. **工作区曾有** `LineDetailPage.tsx` 去掉线路详情「直播模式」下拉的未提交改动 — 若已进 v1.1.9，确认是否故意；直播模式入口应在设备详情等其它页保留。

---

## 4. 下一步计划（建议新会话按序）

1. 读 §9.3 + DEV_PLAN；列出拟改文件清单，等用户点名 +「确认修改」。  
2. **P1** 设备 Web：bypass 表单（IP/掩码/网关 + customer_hosts）+ 超时回滚骨架。  
3. **P2** 单一 `apply-proxy-mode` 编排（幂等、可回滚）。  
4. **P3** nft/DNS/NAT/policy-routing 对齐 §9.3。  
5. 联调：国内 hairpin、`rp_filter=2`、国际 TUN、管理 LAN 小网关自测。  
6. 含固件正式交付时再走 Dataplane-Arch 发版通道（不得假装 OTA Patch）。

---

## 5. 踩过的坑（不要再踩）

| 坑 | 正确做法 |
|----|----------|
| 未批准就改 `NFT_ARCHITECTURE.md` / 生成器 | 先差异表，等「确认修改」；本会话规范已由用户批准写入 |
| 旁路 = 关掉 mangle/策略路由 | **错**；旁路国际仍要 mark→TUN |
| WAN 入向一律 `ct mark 0x2023` | **方案 A，已否决**；用 Option B + `@customer_hosts` |
| 只沿用 LAN DNS 劫持做旁路 | 客户 DNS=8.8.8.8 时完全无效；必须 WAN+customer |
| 客户流量 WAN masquerade | 国内回程拉回 GFC → 易打环；旁路禁止 |
| 用控制面开局切旁路 / 下发 customer_hosts | 开局常不在客户网；**仅设备 Web** |
| 靠 WAN 双 DHCP「静态坏了自动救」 | 不作为主方案；靠 **LAN 管理口 + 超时回滚** |
| 管理网段与 `@customer_hosts` / 旁路 WAN 前缀冲突 | 开局校验拒绝 |
| 改 nft 却当普通 Patch OTA | 数据面至少 Major/Dataplane-Arch + 固件/人工通道 |
| 试编/排错就 bump `PKG_RELEASE` / 产品 tag | 违反 §1.5；本存档 tag 是用户明确要求的发版 |
| 未设 `rp_filter=2` 做 WAN↔WAN 国内转发 | 包被当 martian 丢掉 |
| 用 `docs/draft/*` 当权威 | draft 是副本；以 `docs/*_ARCHITECTURE.md` 为准 |

---

## 6. 关键代码锚点（只读参考）

```
gfc-client/deploy/immortalwrt/gfc-routing.sh     # 现行网关 inet gfc
gfc-client/deploy/lib-unbound-nft.sh             # LAN DNS hijack
gfc-client/deploy/lib-policy-routing.sh          # bypass 当前跳过 policy
gfc-client/deploy/immortalwrt/luci-app-gfc/.../settings.js  # 旁路「待开发」
gfc-client/internal/network/openwrt_wan.go       # WAN static/dhcp（互斥 proto）
docs/NETWORK_APPLY.md                            # WAN 误写 dhcp 丢 IP 事故
```

---

## 7. 其它主线索引（非本会话）

| 主题 | 文档 |
|------|------|
| 固件 OEM / r23 | `FIRMWARE-BUILD-HANDOFF.md` + `SESSION_HANDOFF_2026-07_FIRMWARE_BUILD_FIXES.md` |
| OTA / reclaim | `SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md` |
| Hysteria2 live | 历史 commit / 平台 live_mode（与旁路正交） |

---

*若本文件与 `NFT_ARCHITECTURE.md` 冲突，以 NFT 规范为准，并修本文件。*
