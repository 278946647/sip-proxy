# 会话交接：透明模式开发启动（2026-09-09）

> 写给**无本对话上下文**的新会话：**读规格并直接开发**。  
> 本文件 = 用户对透明一期实现的 **「确认修改」**（含偷流层表名）。  
> **产品唯一真相：** [`docs/TRANSPARENT_MODE.md`](TRANSPARENT_MODE.md)  
> 规格讨论交接（勿当开发入口）：[`SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md)  
> Cursor：`.cursor/rules/transparent-mode.mdc`  
> nft / unbound / sing-box：inet 骨架不变；本批只加已点名的 `netdev gfc_trans`，**禁止**改 `auto_route` / `route.final` / unbound `forward-zone` 语义。

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 规格 | **冻结** → `TRANSPARENT_MODE.md` |
| 开发授权 | **已授权**（2026-09-09） |
| 代码 | **一期已合入**（`netdev gfc_trans` / `internal/transparent` / 设备 Web 开放；确认/回滚对齐旁路） |
| 产品号 / `PKG_RELEASE` | **禁止**因试编升号（§1.5） |
| 正式发版 | 交付时再定级 Dataplane-Arch / Major |

**禁止重开：** proxy-ARP、RFC1918 目的自动放行 53、插线必须先光猫、国际 UDP 进隧道、关劫持就停 unbound、管理 LAN 桥 isp/cpe。

---

## 1. 新会话第一句（用户可整段粘贴）

```
严格按 docs/TRANSPARENT_MODE.md 与 docs/SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md 开发透明一期。
本消息即「确认修改」。
先读上述两文 + NFT_ARCHITECTURE / UNBOUND_ARCHITECTURE / BYPASS_MODE，输出契约 vs 代码差异表（预期：无透明实现），然后按交接 §4 点名文件直接写。
偷流层表名已拍板：netdev gfc_trans（链 in_isp / in_cpe / eg_isp / eg_cpe；set hitch_reply）。先把该表写入 NFT_ARCHITECTURE.md 再写生成器。
inet 表 nat / gfc_dns_hijack / gfc 不改名、不改 hook/默认 mark。sing-box kernel-split 不改 auto_route / route.final。
试编不升产品号。做完按 TRANSPARENT_MODE.md §11 列验收命令。
```

---

## 2. 本批交付范围（一期）

1. **口与桥：** 管理 LAN 独立；`isp_port` + `cpe_port` → `br-trans`（无互联 IP）。口角色设备 Web 指定/对调。  
2. **学习状态机：** `idle` / `cpe_only` / `isp_only` / `dual`。被动学主机。已学到客户后永不抢 CE ARP。`dual` 前可以没有隧道。  
3. **偷流：** 国际 TCP punt 进现有 inet `gfc` → `0x2023 → 2022 → gfctun`。ESP/IKE/GRE 等永不偷；其它 UDP 直通。`bridge-nf` 保持关。  
4. **搭车：** 本机源 IP=CE；TX 只改本机 MAC；回程 `hitch_reply` 五元组 punt。禁止端口段代替五元组。  
5. **DNS：** 默认电缆全拦 53（含私网网关目的），应答源伪装。设备级 `dns_hijack` 三种模式共用。排除列表。透明 DNS VIP 默认 `172.31.253.53/32`（`gfc-dns` dummy）；关劫持仍 punt VIP:53。  
6. **UI：** 开放 `transparent`；切换确认/超时回滚对齐旁路。展示 DNS VIP、口角色、劫持开关、排除列表。  
7. **策略试算：** 透明仅 `dual` 时 `ingress_eligible`。

**非目标：** IPv6 分类、PPPoE 内层、硬件旁路继电器、两口 SKU、DoH/DoT、国际 QUIC 进隧道、控制面写入 `proxy_mode`。

---

## 3. 已批准的新表/口名（先写入 NFT_ARCHITECTURE.md）

不得另起表名。禁止合并进 `inet gfc` / 打开 `bridge-nf-call-iptables`。

| 对象 | 名称 | 说明 |
|------|------|------|
| netdev 表 | `gfc_trans` | 偷流 + TX MAC；family `netdev` |
| isp 入向 | `in_isp` | hitch 回程 punt；其余 L2 |
| cpe 入向 | `in_cpe` | DNS / 国际 TCP punt；协议白名单 L2 |
| isp 出向 | `eg_isp` | 本机帧 `src MAC=CPE` |
| cpe 出向 | `eg_cpe` | DNS/代理回程 `src MAC=PE` |
| 回程 set | `hitch_reply` | inet_proto . 五元组；timeout |
| 透明桥 | `br-trans` | isp+cpe；无 IP |
| CE punt | `gfc-ce` + `gfc-ce-fwd` | veth：`fwd` 打到 fwd 端，本机地址/inet 在 `gfc-ce`；禁止对外答 CE ARP |
| DNS dummy | `gfc-dns` | DNS VIP `/32` |

inet 继续：`nat` / `gfc_dns_hijack` / `gfc`。透明 punt 后的分类走现有 `prerouting_mangle_ct` / `_route`。`dns_hijack=off` 时：网关/旁路去掉「抢非本机 53」；透明电缆不拦 53，仍拦 `daddr=VIP:53`。

---

## 4. 点名文件（只改这些；需要新增则限于下列目录）

### 必须先改（表名登记）

- `docs/NFT_ARCHITECTURE.md` — 登记 `netdev gfc_trans` 与链/set；透明 delta；**不改** 现有 inet 链名/hook/mark

### 数据面生成器

- `gfc-client/deploy/immortalwrt/gfc-routing.sh`
- `gfc-client/deploy/lib-unbound-nft.sh`
- `gfc-client/deploy/gen-nft-policy.py`（若本批透明规则走该生成器）
- `gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh`
- `gfc-client/deploy/apply-network.sh`（仅透明桥/口/dummy 所需）

### Agent / API / 模式

- `gfc-client/internal/proxymode/`（去掉「尚未开放」；校验口角色；回滚对齐旁路）
- **新增** `gfc-client/internal/transparent/`（学习、状态机、hitch 表维护、ARP 纪律、VIP 冲突避让）
- `gfc-client/internal/api/proxymode.go` 及透明/DNS 开关相关 API
- `gfc-client/internal/policyrouting/probe.go`（`ingress_eligible`）

### DNS

- unbound ACL：允许学到的客户源 + DNS VIP 查询；**禁止** `0.0.0.0/0 allow`
- `gfc-client/internal/render/unbound/` 仅当 ACL/VIP 需要；**禁止**改 `forward-zone` 国内国际语义
- 透明 53 应答源伪装（trampoline / TPROXY / `snat to ct original daddr`）；禁止裸 `redirect` 把源变成盒子

### 设备 Web

- `gfc-client/deploy/immortalwrt/luci-app-gfc/htdocs/luci-static/resources/view/gfc/settings.js`
- `gfc-client/web/src/views/maintenance/settings/index.vue`（若与 LuCI 双轨，行为必须一致）

### 文档（实现与规格对齐时）

- `docs/TRANSPARENT_MODE.md` 仅当发现规格漏洞且用户同意改语义
- `docs/UNBOUND_ARCHITECTURE.md` §2.1 实现后把「not implemented」改为已落地锚点
- 本交接：阶段完成后更新 §0 状态

**禁止改：** `SINGBOX_ARCHITECTURE.md` 契约字段；`route.final` / `auto_route`；`TO_CN`/`bypass_ip`/`ext_const` 写入学习 IP；Makefile `PKG_RELEASE`。

---

## 5. 建议实现顺序

1. 登记 `NFT_ARCHITECTURE.md` § 透明 `gfc_trans`（对照现有 gateway/bypass 写法）。  
2. `internal/transparent` 学习+状态机（可先单测，不依赖真网卡）。  
3. `gfc-routing.sh` / nft：建 `br-trans`、netdev 规则、fail-open（规则失败则纯桥）。  
4. 搭车：veth `gfc-ce`/`gfc-ce-fwd`、SNAT、`hitch_reply`、TX MAC。  
5. DNS punt + VIP `gfc-dns` + 三种模式 `dns_hijack` + 排除列表。  
6. LuCI/Web：开模式、口角色、开关、VIP 展示、确认回滚。  
7. `verify-dataplane-dns.sh` 与 §11 验收命令。

对照实现：旁路 `internal/proxymode` + `gfc-routing.sh` Option B。透明是第三种入向，不要复用 `customer_hosts` 当学习结果。

---

## 6. 验收（实现后）

见 `TRANSPARENT_MODE.md` §11。最低限度：

- `dual` 下盒子不对 CE 答 ARP；公网/IPsec 到 CE 仍 L2 给客户  
- 国内 TCP TTL 不因 GFC 减 1；国际 TCP 进 `gfctun`（`ip rule` 仍有 `0x2023`）  
- 劫持 on：CE→114 或私网网关:53，应答源仍是原目的  
- 劫持 off：上述不抢；`CE→DNS VIP:53` 仍进 unbound  
- 管理 LAN 不在 `br-trans`；`bridge-nf-call-iptables=0`

---

## 7. 用户口令

> 严格按 `docs/TRANSPARENT_MODE.md` 与 `docs/SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md`，只改点名文件。`netdev gfc_trans` 先写入 `NFT_ARCHITECTURE.md` 再写生成器。禁止改 kernel-split 与 unbound 拆解析语义。试编不升号。
