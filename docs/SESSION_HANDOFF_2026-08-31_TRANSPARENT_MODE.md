# 会话交接：透明模式（2026-08-31）

> 规格讨论冻结交接。 **开发入口已改：** [`SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md)  
> **产品 / 入向 / ARP / 偷流 / DNS 唯一真相：** [`docs/TRANSPARENT_MODE.md`](TRANSPARENT_MODE.md)  
> 数据面骨架：[`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)、[`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)、[`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)  
> 旁路对照：[`BYPASS_MODE.md`](BYPASS_MODE.md)（透明 ≠ 旁路）  
> 策略模型：[`USER_POLICY_ROUTING.md`](USER_POLICY_ROUTING.md)  
> Cursor：`.cursor/rules/transparent-mode.mdc`；nft / unbound / sing-box 仍走各自 no-change-without-approval  
> 同日泛域名交接：[`SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md`](SESSION_HANDOFF_2026-08-31_WILDCARD_FQDN.md)（另一能力，勿混）

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 需求讨论与拍板 | **已完成**（2026-08-31） |
| 规格 / 开发规范 | **已完成** → `TRANSPARENT_MODE.md` |
| Agent / 生成器 / LuCI | 开发入口见 **09-09** 交接 |
| nft 偷流层表名 | 已在 09-09 交接拍板：`netdev gfc_trans` |
| 设备 Web `transparent` | 随 09-09 开发批开放（确认/回滚对齐旁路） |
| 产品版本 / `PKG_RELEASE` | **禁止**因本规格或试编升号 |

**禁止**把「要不要 proxy-ARP」「RFC1918 目的就放行 53」「插线必须先光猫」当未决重开。要改语义须用户明确改规格。

---

## 1. 业务需求（已拍板）

现场把 GFC **串在** 客户设备与上游（光猫 / 对端路由器）之间：客户互联地址不变（公网 /30 或私网都行），公网仍能打到客户 CE，IPsec 仍当电缆；盒子自己要有控制面和 VLESS，并做国内国际分流。

| 拍板 | 取值 | 不要理解成 |
|------|------|------------|
| 数据面 | L2 默认直通 + 选择性 punt 进现有 inet/TUN | 整机桥接；旁路填公网 hosts |
| 盒子地址 | 搭车学到的 CE；稳态不抢 ARP | 再要一个互联 IP；proxy-ARP |
| 国际 | 一期只偷 TCP | 国际 UDP/QUIC 进隧道 |
| DNS | 默认全拦 53（含私网网关当 Option 6） | 目的 RFC1918 就放行 53 |
| 关劫持 | 三种模式同一开关；透明自愿入口=DNS VIP | 关劫持 = 关 unbound；透明「指向网关 IP」 |

---

## 2. 收口时冻结的默认（讨论未单独展开，避免开发重开）

| 项 | 冻结值 | 出处 |
|----|--------|------|
| VLAN | 默认只处理 untagged IPv4；tag 默认 L2；Web 可声明业务 VLAN | 防 IPTV |
| IPv6 | 整帧 L2，不劫持 AAAA 路径 | 与 unbound `do-ip6: no`、现网 IPv4-only nft 一致 |
| PPPoE | L2 直通，不拆内层 | 另开模式 |
| 口角色 | 设备 Web 指定 isp/cpe | 禁止自动猜上下游 |
| DNS VIP | 默认 `172.31.253.53/32`，保留池冲突避让 | 禁止 `198.18.0.0/15` |
| 硬件旁路继电器 | 非目标 | 独立 SKU |
| 两口 SKU | 非默认 | 三口：管理+isp+cpe |
| 控制面 | 只读 | 与旁路 `proxy_mode` 相同 |

---

## 3. 规范 vs 实现（下一会话先做这件事）

权威：`TRANSPARENT_MODE.md`。代码 **尚无** 透明实现。

| 规范项 | 预期位置（未写） | 下一会话 |
|--------|------------------|----------|
| `proxy_mode=transparent` 拒绝 | LuCI settings / `proxymode` | 未交付前保持拒绝 |
| 学习 / 状态机 | 新包（建议 `internal/transparent/` 或 `proxymode` 旁） | **先规格对照，勿先写生成器** |
| hitch 五元组 / TX MAC | Agent + nft netdev/bridge | 等确认后再动生成器 |
| DNS VIP dummy | Agent + unbound ACL | 关劫持仍 punt VIP:53 |
| `dns_hijack` 开关 | 三种模式共用；动 `gfc_dns_hijack` | 须确认修改 |
| 用户策略入向 | `policyrouting` 试算 `ingress_eligible` | 透明 `dual` 才 eligible |

发现与契约不一致：**报 bug 后按规格改代码**，不得改规格迁就。

---

## 4. 下一会话开发顺序

> 严格按 `docs/TRANSPARENT_MODE.md`，只改我点名的文件。  
> nft/unbound/sing-box 生成器改前先 diff，我确认后再写。  
> 试编排错不升产品号。

### 阶段 0 — 只读（先做）

1. 读本文 + `TRANSPARENT_MODE.md` + `.cursor/rules/transparent-mode.mdc`  
2. 读 `NFT_ARCHITECTURE.md` / `UNBOUND_ARCHITECTURE.md` / `BYPASS_MODE.md`  
3. 输出 **契约 vs 当前代码** 差异表（预期：无透明实现；列出将动的生成器与新表是否需要登记）  
4. **停**。未经用户「确认修改」不得写 nft/unbound/sing-box 生成器，不得启用 Web 上的 `transparent`

### 阶段 1 — 仅在确认后

1. 先把偷流层表/链名写入 `NFT_ARCHITECTURE.md`（用户已确认的名字）  
2. 再写生成器 + 学习/状态机 + DNS VIP + 三种模式 `dns_hijack`  
3. LuCI：口角色、开关、排除列表、展示 VIP；模式切换确认/回滚对齐旁路  
4. 验收按 `TRANSPARENT_MODE.md` §11  

### 不要做

- 顺手改 kernel-split / unbound forward-zone / 泛域名匹配语义  
- 用 ebtables + `bridge-nf` 当正式实现  
- 为联调 bump `PKG_RELEASE`

---

## 5. 与其它交接的边界

| 主题 | 文档 | 透明会话不要重开 |
|------|------|------------------|
| 旁路 Option B | `BYPASS_MODE.md` | 公网 hosts、WAN 不全量 mark |
| 泛域名一层 `*` | `USER_POLICY_ROUTING.md` §2.3 | 嗅探实现后须覆盖 isp/cpe 口，但仍是 §2.3 语义 |
| 固件 / 版本 | `VERSION_AND_RELEASE.md` §1.5 | 试编不升号 |

---

## 6. 用户口令（建议每轮附带）

> 严格按 `docs/TRANSPARENT_MODE.md`，只改我点名的文件；nft/unbound/sing-box 生成器改前先 diff，我确认后再写。试编不升号。
