# 会话交接：VLESS + Hysteria2 双通道 · 直播模式 · 域名分类集（2026-07-24）

> 写给**无本对话上下文**的新会话。本文件是讨论结论与开发需求权威摘要。  
> **本批尚未写业务代码**；落地前须走 dataplane「确认修改」。  
> 规则：[`docs/SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)、[`docs/NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)、[`docs/UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)、[`docs/VERSION_AND_RELEASE.md`](VERSION_AND_RELEASE.md) §1.5  
> Cursor：`.cursor/rules/singbox-no-change-without-approval.mdc`、`nft-…`、`unbound-…`、`gfc-version-release.mdc`

---

## 0. 一句话状态

| 项 | 状态 |
|----|------|
| 方案讨论 | **已收敛**（双通道 + 线路直播模式 A/B + 平台分类集 + §4A 预解析/防串） |
| 代码实现 | **P0 进行中**（`standard` + `live_all_hy2`；字段 `live_mode`；Hy2 `:18443`） |
| 回退钉扎 | **已切并 push** `milestone/pre-hysteria2-20260724` → commit `e8e111d` |
| 产品版本 | **不因本讨论/试开升号**；正式发版再走矩阵 / tag `vX.Y.Z` |
| 数据面改动 | nft / unbound / ip rule **一期零改**；sing-box 已按批准扩展 |

回退：

```bash
git fetch --tags origin
git checkout milestone/pre-hysteria2-20260724
# 再按该点部署 node-agent / 客户端；非一键还原 /etc 运行配置
```

---

## 1. 业务目标（已拍板）

1. **保留** 现网默认：国际流量 → VLESS + Reality（抗 DPI 主通道）。  
2. **同节点** 并行 Hysteria2 备通道；用于对抗公网高 RTT / 抖动 / 丢包（直播观测与生产可选）。  
3. **换节点 / 换 SOCKS 资源** = 最后手段；先协议层 A/B 观测。  
4. 「指定直播流」= **平台服务分类集 × 线路**，**不是**完整 m3u8/RTMP URL 库。  
5. 控制面入口：**线路详情 → 代理模式 → 直播模式**（两种子模式，见 §3）。

---

## 2. 架构原则（已拍板）

```text
L1 nft (kernel-split，默认不改表/链/mark)
  国内/private/bypass → WAN
  国际 → mark 0x2023 → table 2022 → gfctun

L2 sing-box（本需求主战场）
  tun-in → route → proxy (VLESS) | proxy-hy2 (Hysteria2)
  同 lineId → 节点侧落到同一 SOCKS（切协议 ≠ 换出口）

L3 节点
  vless-reality-in :8443  +  hysteria2-in :<评审端口>
  身份均映射 client-{lineId}；未知用户 final: direct
```

| 决策 | 取值 |
|------|------|
| 隧道形态 | **同 TUN、双 outbound**（不新开 mark/table/第二 TUN，除非二期证明需要） |
| Hy2 对端 | **与 VLESS 同一节点 IP**（`node.address`） |
| nft `bypass_ip` | **一期不扩成员**（节点 IP 已在集内即可覆盖 Hy2 出站）；若 Hy2 改用其它 IP/CDN 则必须补 bypass |
| 自动故障切 Hy2 | **一期不做**（人工/线路模式切换；失败不静默直连） |
| OpenVPN / WireGuard | **不进入**本需求客户端双通道 |

---

## 3. 产品逻辑：线路「直播模式」

### 3.1 模式枚举

| `proxy_mode`（建议字段名） | UI 名称 | 行为 |
|----------------------------|---------|------|
| `standard`（默认） | 标准 / Reality | 国际 → **全部 VLESS**；**sniff 关** |
| `live_catalog` | 直播模式 A · 目录分流 | catalog 命中 → **Hy2**；其余国际 → **VLESS**；见 §3.3 |
| `live_all_hy2` | 直播模式 B · 全国际 Hy2 | 国际 → **全部 Hy2**；VLESS **不承载业务**；**sniff 关** |

**模式 B 语义（已确认）**：仅指 **直播模式下的 B** = **全国际进 Hy2**。  
**不是** nft `global`（国内不进 TUN）。文案禁止写成「所有流量才进入 sing-box」（国际流量本就进 sing-box）。

### 3.2 模式 B — sing-box 形态（概念）

```text
outbounds: direct*, proxy(vless), proxy-hy2(hysteria2)
route:
  bypass / private / domestic:53 → direct
  ext_const / catch-all → proxy-hy2
sniff: false
```

### 3.3 模式 A — sing-box 形态（概念）

```text
route:
  bypass / private / domestic:53 → direct
  live 命中 (ip_cidr @live_ip 优先; 可选 domain_* ) → proxy-hy2
  其余国际 → proxy (VLESS)
sniff: 仅当需要 domain 规则时开启（见 §4）
```

线路可勾选 `live_platforms[]`（TikTok、Shopee…）合并为 endpoint 集。

### 3.4 观测工作流（运维）

1. 分段压测：网关→节点 / 节点→SOCKS / 码率。  
2. 瓶颈在网关→节点 → 同节点切 `live_all_hy2` 或 A 观测 15–60min。  
3. **固定**：同一 `lineId`、同一 SOCKS、同一推流机；只变传输。  
4. 校验出口 IP 切换前后一致。  
5. 仍差 → 查 UDP QoS → 再考虑换节点/出口。

---

## 4. Sniff 策略（已拍板方向）

| 模式 | sniff | 说明 |
|------|-------|------|
| `standard` | **关** | 现状 |
| `live_all_hy2` | **关** | 无需按域名分支 |
| `live_catalog` | **按需开** | **优先 IP 预解析**；domain 规则才开 sniff |

**影响认知**：

- 性能：通常中低（连接建立期）；不是第一风险。  
- 正确性：纯 RTMP 常 **无 SNI** → 仅靠 sniff 会漏；故 ingest **以 IP/CIDR 为主**。  
- 开关：挂在 **`live_catalog`**，不要「凡直播模式都开 sniff」。

**模式 A 匹配优先级**：

1. 官方/API/抓包得到的 ingest → 解析写入动态 `live_ip` → `ip_cidr` → Hy2。  
2. RTMPS/HTTPS → 可选 sniff `domain_suffix` 补漏。  
3. 过宽 CDN suffix 默认不进 `active`（防误伤浏览流量）。

---

## 4A. 模式 A · IP 预解析（权威澄清 · 必读）

> **硬约束**：解析视角 = 该线路指定出站（SOCKS 或 direct）；存档主键 = **`line_id`**。  
> **禁止**：节点级「一份总表」合并多条 SOCKS 的解析结果。  
> **防串校验 + 不一致告警 = P0**，不可降级为可选。

### 4A.1 要锁死的是「视角」，不是「进程必须在节点」

| 说法 | 对错 |
|------|------|
| 必须从该线路 SOCKS（或 direct）出口视角做 DoH/DNS | **对** |
| 进程物理上只能跑在转发节点 | **不对**（节点是默认推荐执行点） |
| GFC 盒子绝对不能预解析 | **不对**（路径正确即可；单线盒子甚至更贴近 LAN DNS） |

推荐默认：**转发节点集中执行**（多线、省嵌入式负载）；允许盒子侧同路径实现。

### 4A.2 何时开始 / 何时停止

| 触发 | 动作 |
|------|------|
| 线路进入 `live_catalog` | **立即**跑一轮 |
| catalog / endpoint 变更或审核通过 | **立即**跑一轮 |
| 模式 A 持续开启 | **定时刷新**（见 4A.5） |
| SOCKS 从不通→通 | **立即**补解析 |
| 设备新绑定该线路且模式 A 已开 | 可补一轮后下发 |
| `standard` / `live_all_hy2` | **不跑**预解析 |
| 退出模式 A | **停止**；可保留过期集并标 stale |

推流开始那一刻才首次解析 → **太晚**（前几秒可能仍走 VLESS）。

### 4A.3 如何经指定 SOCKS 解析（实现要点）

```text
for line in lines where proxy_mode == live_catalog:
  1) 读出站：socks → detour=client-{lineId}；direct → detour=direct
  2) 健康检查：SOCKS/出站不可用 → 本轮跳过，保留旧集并告警；禁止静默改用其它线 SOCKS 或节点 WAN 当成功
  3) DoH（如 https://1.1.1.1/dns-query）经该 detour 发出（TCP/443，与现有 node dns-* + detour 同构）
  4) 写入 store[line_id] = { domain → ips[], egress_hint, resolved_at, ttl }
  5) 上报控制面；只把该 line 的结果下发给绑定该 line 的盒子
```

- **不要**在节点上对 ingest 域名做裸 `dig`（那是节点 WAN 视角）。  
- 多线示例（马/新/越三条 SOCKS）：**三次独立解析、三份独立存档**，禁止 `union`。

### 4A.4 存档位置与隔离（防马客户吃到越记录）

| 层 | 路径/形态（建议） | 主键 | 角色 |
|----|-------------------|------|------|
| **控制面 DB** | `live_resolve_result` 表（权威） | **`line_id`** | 唯一真相；审计；下发源 |
| **转发节点缓存** | `/var/lib/gfc-node/live_resolve/line-{lineId}.json` | **`line_id` 分文件** | 执行缓存；**禁止**单一 `live_ip.json` 总表 |
| **GFC 盒子** | `/etc/gfc-client/live_ip.line-{lineId}.json`（或生成进 sing-box/nft 时内嵌） | **仅当前绑定 line** | 模式 A 路由用 |

串线危害（即使仍是同一平台 hostname）：错误边缘 → RTT/丢包变差；与终端 DNS 不一致 → **模式 A 漏匹配**仍走 VLESS；部分区域 ingest 更不稳。  
**不是**「推到别人账号」，但是 **出口视角串了 → 分流与质量双杀**。

### 4A.5 频率

| 项 | 建议 |
|----|------|
| 默认周期 | **约 5 分钟** 全量刷新（可配置） |
| 结合 TTL | `clamp(min_TTL, 60s, 600s)` 可作进阶 |
| 下限 | ≥ **60s**（防打爆 DoH/SOCKS） |
| 上限 | ≤ **10–15 分钟**（防集过旧） |
| 变更 | catalog 变更 **即时**，不计入定时 |

### 4A.6 存储体量大不大？

**不大。** 量级估算（单 line）：

| 因子 | 典型量级 |
|------|----------|
| 勾选平台 × ingest 域名 | 约 10–50 个 FQDN（一期更少） |
| 每域名 A/AAAA | 约 1–8 条 |
| 单 line JSON | 通常 **数 KB～几十 KB** |
| 节点 50 条模式 A 线路 | 缓存合计通常 **&lt; 数 MB** |
| 控制面 | 按 line 行存储，远小于日志/流量计量 |

不存 m3u8/视频、不存完整推流 URL；只存域名→IP 与元数据。闪存与 DB 压力可忽略；真正成本是 **周期性 DoH 短连接**（仍远小于直播码率）。

### 4A.7 下发与使用硬校验（防串 · P0 · 不一致必须告警）

实现时 **必须全部落地**；任一失败 → **不得静默使用错误集**：

| # | 校验 | 失败动作 |
|---|------|----------|
| V1 | 解析任务 `detour` outbound tag **必须** `== client-{lineId}`（或该线配置的 direct） | 中止本轮；**告警** |
| V2 | 写入 DB/文件的 `result.line_id` **必须**与任务 `line_id` 一致 | 拒绝 commit；**告警** |
| V3 | 下发盒子：bundle 中 `live_ip.line_id` **必须** `== device.bound_line_id` | 拒绝应用 / 不更新路由集；**告警** |
| V4 | 生成器断言：不得把其它 line 的 IP 并入本机 `live_ip` | build/apply 失败；**告警** |
| V5 | 结果带 `egress_hint`（SOCKS host/region）时，与线路 SOCKS 元数据比对 | 不一致 → **告警**，本轮结果标 `rejected` 或 `degraded`，保留上一份 ok 集 |
| V6 | SOCKS 不健康时禁止用节点 WAN / 其它线 SOCKS 的解析冒充成功 | **告警** `resolve_vantage_mismatch`；保留 stale |
| V7 | （可选加强）抽样探测：解析任务自身出口 IP ∈ 该线路 expected 出口 | 不一致 → **告警**并丢弃本轮 |

告警通道：控制面告警事件 + 节点/agent 日志（级别 error/warn）；UI 线路详情可见「live_ip 校验失败 / 视角不一致」。  
**无告警的静默混用 = 缺陷。**

### 4A.8 政策一句话

> 模式 A 专用；按 `line_id` 在「指定出站健康」前提下 DoH；默认节点约 5 分钟刷新、变更即时；权威在控制面按线存储；盒子只收本线；**防串硬校验失败必须告警且不得污染 active `live_ip`**。

---

## 5. Hysteria2 伪装（已拍板方向）

| 项 | 建议默认 |
|----|----------|
| 形态 | TLS +（评审端口，倾向 443/udp 或独立高位端口二选一） |
| Masquerade | **开**（探测像站点） |
| Obfs Salamander | **默认关**；QUIC/H3 被针对性封锁时按部署打开 |
| 强度预期 | **≤ Reality**；不替代默认抗审查入口 |
| Brutal | 可开但须 **上行带宽上限**（避免打满触发运营商 QoS） |

官方参考：Hysteria2 Client/Server 文档（masquerade / salamander）。

---

## 6. 直播平台分类集（产品可行 / 数据不完全）

### 6.1 数据模型

```text
LivePlatform
  id, display_name, markets[], live_strength (strong|weak)

LiveEndpoint
  platform_id
  role: ingest | shop_api | cdn_play | control
  match: fqdn | domain_suffix | ip_cidr
  value
  confidence: high | medium | low
  source: official_doc | official_api | capture | geosite_seed
  status: draft | active | retired
  last_verified_at
  region / market (可选)
```

**禁止**：完整带 token 的 stream URL 作为路由键。

### 6.2 平台清单（UI 应覆盖；active 种子分级）

| id（建议） | 平台 | 库可行性 | 一期策略 |
|------------|------|----------|----------|
| `tiktok_shop` | TikTok Shop / LIVE | 中 | draft + 抓包；区域分集 |
| `shopee_live` | Shopee Live | 中 | 按市场分集 |
| `lazada_live` | Lazada Live | 中 | 按市场分集 |
| `amazon_live` | Amazon Live（购物） | 中 | 与 IVS 拆开 |
| `amazon_ivs` | Amazon IVS / `*.live-video.net` 类 | 中 | suffix 候选，勿绑整站 amazon.com |
| `whatnot` | Whatnot | 中低 | 抓包 |
| `kwai_shop` | Kwai / Kwai Shop | 中低 | 抓包 |
| `temu` | Temu | 低（直播弱） | UI 可有；默认不 active / 提示误伤 |
| `aliexpress` | AliExpress | 低–中 | 严分 ingest vs 浏览 |
| `ebay_live` | eBay Live | 中低 | 抓包 |
| `walmart_live` | Walmart Live | 中低 | 抓包 |
| `shopify_live` | Shopify + 第三方推流 | 特殊 | 按 **推流服务商** 子类，禁止只写 shopify.com |
| `youtube_live` | YouTube Live / Shopping | **高** | P0 active 种子 |
| `facebook_live` | Facebook Live Shopping | 中 | Meta 窄 suffix + 抓包 |
| `instagram_live` | Instagram Live / Shopping | 中低 | 挂 meta 父集；禁止整站 instagram.com 进 Hy |

**对照高置信（非电商表但可复用技术）**：Twitch `GET https://ingest.twitch.tv/ingests`。

**种子来源（审核）**：

- YouTube：Support RTMPS / Studio Stream URL；主机如 `a.rtmp.youtube.com`、`b.rtmp.youtube.com`。  
- Twitch：官方 ingest API。  
- Amazon IVS：文档中的 per-channel `*.live-video.net` 形态。  
- TikTok 等：无可靠全球公开 ingest 全集 → **抓包补全 + 人工审核**；geosite 仅 seed。

无 active 种子的平台：UI 勾选时提示「建议模式 B」或「先学习抓包」。

---

## 7. 复盘：不合理点与优化（讨论后修正）

| # | 原表述 / 风险 | 修正 |
|---|----------------|------|
| 1 | 「直播 URL 库」 | 改为 **平台 endpoint 分类集**（域名/后缀/IP） |
| 2 | 「模式 B = 所有流量进 sing-box」 | 改为 **全国际 → Hy2**；国际本就进 sing-box |
| 3 | 模式 A 只靠 domain sniff | **IP 预解析优先**；RTMP 无 SNI |
| 4 | 凡直播开 sniff | 仅 **`live_catalog` 按需**；B/标准关闭 |
| 5 | Hy2 默认上 Salamander | **默认 masquerade；Salamander 可选** |
| 6 | 认为 bypass 永远不用动 | **同节点同 IP 一期可不扩**；换 IP/CDN 必须扩 |
| 7 | 每个电商平台都有完整 ingest 表 | **UI 全做；数据分级**；不全则模式 B |
| 8 | Shopify/Temu 当普通 ingest 后缀 | Shopify→推流商子类；Temu→弱直播/慎选 |
| 9 | Instagram/Facebook 整站进 Hy | **窄匹配 + 置信度**；防误伤社交刷流 |
| 10 | 自动 VLESS→Hy2 故障转移 | 一期 **不做**（与「失败不静默直连」一致） |
| 11 | 用目录拷贝备份节点 | 用 **git milestone tag**（已 push） |
| 12 | 开发时顺带改 nft 分流架构 | **禁止**未经批准改表/链/mark/priority |
| 13 | 预解析「必须只能在节点」 | 锁的是 **SOCKS 视角**；节点默认执行，盒子可同路径 |
| 14 | 节点多 SOCKS 共用一份 live_ip | **禁止**；主键 **`line_id`** 分存 |
| 15 | 防串校验可后补 | **不可**；不一致 **必须告警**且不得污染 active 集 |

---

## 8. 开发需求（供实现拆分）

### 8.1 P0 — 双通道可切换（模式 B + 标准）

| 组件 | 需求 |
|------|------|
| 控制面 | 线路 `proxy_mode`: `standard` \| `live_all_hy2`；bundle 下发 Hy2 凭证（与 VLESS 并列） |
| 节点 | 生成 `hysteria2-in`；用户映射到 **同一** `client-{lineId}` SOCKS/direct；`final: direct` |
| 客户端 | outbound `proxy-hy2`；模式 B catch-all → hy2；标准 → proxy；**sniff 关** |
| 伪装 | masquerade 开；salamander 可配置默认关；带宽上限字段 |
| 诊断 | 双通道连通/延迟；切换前后出口 IP 一致校验 |
| 兼容 | 老客户端无 Hy2 → 忽略 `live_*` 或拒绝并提示升级 |

### 8.2 P1 — 模式 A（目录分流）

| 组件 | 需求 |
|------|------|
| 控制面 | `live_platforms[]`；endpoint CRUD；draft/active；抓包候选审核；**`live_resolve_result` 按 `line_id` 权威存储** |
| 节点 | 仅对模式 A 线路、经 **本线** SOCKS DoH 预解析；缓存 **`line-{id}.json` 分文件**；见 **§4A** |
| 客户端 | 只应用 **本机绑定 line** 的 `live_ip`；`ip_cidr` → hy2；其余 vless；**仅 A 按需 sniff** |
| **防串（P0）** | §4A.7 校验 V1–V7：**不一致必须告警**，拒绝 commit/下发/应用错误集 |
| DNS | 改 unbound 钩子须单独批准；预解析优先节点 DoH+detour（与现网 dns detour 同构） |

### 8.3 P2 — 平台种子与运营

- P0 种子：YouTube（+ 可选 Twitch 技术对照）。  
- P1：TikTok / Shopee / Lazada / Facebook 区域 draft。  
- 抓包「学习窗口」→ CaptureCandidate → 审核 → active。

### 8.4 明确不做（本需求范围外）

- 第二 fwmark / 第二 TUN（除非 P0 压测失败另立评审）。  
- WireGuard 客户端通道。  
- 用 Hy2 替换 Reality 默认。  
- 完整 URL 爬虫库。  
- 试编/排错 bump 产品版本号。

---

## 9. 开发前必须「确认修改」的清单

未获用户 **「确认修改」**（或等价批准）前：**只读分析，不改下列生成器/契约代码**。

### 9.1 Sing-box（必批）

- [ ] Client 新增 outbound tag（建议 `proxy-hy2`；selector 名待定）。  
- [ ] Client `route` 顺序扩展（模式 A/B）。  
- [ ] Client `tun-in` 条件 sniff。  
- [ ] Node 新增 inbound tag（建议 `hysteria2-in`）与 listen 端口常量。  
- [ ] Node 用户→`client-{lineId}` 映射字段（对齐现有 `auth_user` 隔离语义）。  
- [ ] 更新 `docs/SINGBOX_ARCHITECTURE.md` 与之同步。  
- [ ] **禁止**：`proxy-prefer` 加入 `direct`；`route.final` 改成代理；TUN `auto_route: true`。

### 9.2 NFT（默认一期不改；有则必批）

- [ ] 一期目标：**零改表/链/mark/priority**。  
- [ ] 仅当 Hy2 对端 ≠ 现有节点 IP，或新增动态集名时，先出 **规范 vs 实现差异表** 再批。  
- [ ] **禁止**：重命名 `gfc` / `bypass_ip` / `0x2023` / table `2022`。

### 9.3 Unbound（默认一期不改）

- [ ] 模式 A 若要「解析钩子写 live_ip」，须按 `UNBOUND_ARCHITECTURE` 先差异表再批。  
- [ ] **禁止**：dnsmasq `:53`、MosDNS 替 unbound、forward-zone 塞进 `server:`。

### 9.4 控制面 / 版本

- [ ] Bundle / 线路 API 契约变更说明。  
- [ ] 能力协商（节点/客户端是否支持 Hy2）。  
- [ ] 模式 A：`live_resolve_result` 按 `line_id`；下发防串校验与告警事件（§4A.7）。  
- [ ] 正式交付发版时：定级（至少涉及 dataplane → Major 或 Dataplane-Arch 通道）+ `VERSION_MATRIX` + CHANGELOG；**试开发不升号**。

### 9.5 用户固定口令（建议每轮附带）

> 严格按 `docs/SINGBOX_ARCHITECTURE.md`（及 NFT/UNBOUND），只改我点名的文件，改前先给差异表，我确认后再写代码。  
> 回退基线：`milestone/pre-hysteria2-20260724`（`e8e111d`）。  
> 试编排错不升产品版本（§1.5）。

---

## 10. 建议实现顺序（新会话）

1. 读本文件 §0–§9（**含 §4A 预解析/防串**）+ 三份 ARCHITECTURE。  
2. 输出 **规范 vs 拟议实现差异表**（sing-box 必填；nft/unbound 写「无变更」或具体 diff）。  
3. 等用户 **「确认修改」** + **点名文件列表**。  
4. 先落地 **P0：standard + live_all_hy2**（同节点、同 SOCKS、masquerade）。  
5. 压测签字后再开 **P1 live_catalog**（预解析按 line 隔离 + §4A.7 告警必做）。  
6. 不满意：`checkout milestone/pre-hysteria2-20260724` 回退代码基线。

---

## 11. 验收草案（实现后）

| ID | 项 | 通过标准 |
|----|-----|----------|
| HY-01 | 标准模式 | 国际走 VLESS；Hy2 可探测但无业务量（或未选中） |
| HY-02 | 模式 B | 国际走 Hy2；国内仍直连；出口 IP = 原 SOCKS |
| HY-03 | 同 line 映射 | VLESS/Hy2 同一 `client-{lineId}`；未知用户不进他人 SOCKS |
| HY-04 | bypass | 节点 IP 出站不进 TUN（无环路） |
| HY-05 | 失败语义 | Hy2/VLESS 失败不静默 WAN 直连国际 |
| HY-06 | sniff | B/标准 conf 无 sniff；仅 A 按需 |
| HY-07 | 伪装 | masquerade 生效；salamander 默认关可配 |
| HY-08 | 回退 | 文档/tag 可检出 milestone 部署 |
| HY-09 | 预解析隔离 | 同节点多 SOCKS 时各 `line_id` 结果互不合并；马线不得含越线视角 IP |
| HY-10 | 防串告警 | 人为制造 line_id / egress 不一致时：**告警发出**且错误集 **未**写入 active / 未应用于盒子 |
| HY-11 | 存储 | 单 line 解析缓存为 KB 级；无巨型文件 |

直播效果：**架构可承载，效果依赖线路**；须真实推流 A/B 签字（与 `docs/TEST_PLAN.md` 直播 ⚠️ 一致）。

---

## 12. 相关对话结论索引

- 直播卡顿应分段归因；Hysteria2 有条件优于 TCP VLESS，非银弹。  
- WireGuard 不适合作默认跨境抗封锁；OpenVPN 保持可选骨干。  
- 域名分类集：产品全覆盖可行；完整 ingest 数据不可承诺；模式 B 为不全表兜底。  
- IP 预解析：锁 SOCKS 视角；默认节点执行、按 `line_id` 分存；体量小；**防串硬校验 + 告警为 P0**（详 §4A）。

---

## 13. 文档维护

| 动作 | 说明 |
|------|------|
| 本文件 | 讨论完成态；开发推进时更新 §0 状态与验收结果 |
| ARCHITECTURE | 仅在「确认修改」后与代码同步更新 |
| 产品 tag | 正式发版另切 `vX.Y.Z`；勿把 milestone 当产品版本 |

**里程碑远端**：`origin` tag `milestone/pre-hysteria2-20260724`（annotated → `e8e111d`）。
