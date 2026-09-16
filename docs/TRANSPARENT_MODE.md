# GFC 透明模式（`proxy_mode=transparent`）产品与数据面契约

**Status:** 规格已拍板。一期实现已按 2026-09-09 交接合入（`netdev gfc_trans` + 设备 Web 开放 `transparent`，确认/回滚对齐旁路）。  
**权威本文：** 透明入向、学习、ARP、搭车、偷流、DNS VIP、跨模式 DNS 劫持开关。  
**权威 nft 骨架：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md)（inet 表/链/hook/默认 mark **不变**；偷流层 `netdev gfc_trans` 见 §9.4）  
**权威 DNS：** [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)（LAN/客户递归仍为 unbound；禁止 MosDNS / sing-box DNS inbound）  
**权威 sing-box：** [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)（kernel-split **不随** `proxy_mode` 改 `auto_route` / `route.final`。透明省略 VLESS/`direct` `bind_interface`。`route.default_interface`：仅透明且 **无 veth**、`br-trans` 存在时为该桥（MAC-punt）；**`gfc-ce`/`gfc-ce-fwd` 存在则省略**（hitch RX 在 `gfc-ce`，禁止 `SO_BINDTODEVICE br-trans`）。网关/旁路仍为 WAN，禁止全局写死 `br-trans`。SINGBOX 正文若仍写「透明一律 br-trans」，以本文与 09-16 交接为准，待确认后改 SINGBOX）  
**旁路对照：** [`BYPASS_MODE.md`](BYPASS_MODE.md)（旁路 = 客户改网关且 GFC 有 WAN IP；透明 ≠ 旁路）  
**策略模型：** [`USER_POLICY_ROUTING.md`](USER_POLICY_ROUTING.md)（网关 / 旁路 / 透明同一 `policies[]`，只变入向）  
**会话交接（下一步入口）：** [`SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md`](SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md)（veth runtime 里程碑；cpe 直挂交换机多 PC 规格已写入本文 §4–§7。全量测试排在该功能实验室验收之后）  
**上一实验室闭环：** [`SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md`](SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md)  
**一期实现批准：** [`SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md)  
**规格讨论交接：** [`SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md)

若实现与本文冲突，报 **bug**，不得用实现倒逼改本文。inet 表/链/hook/默认 mark 仍禁止擅自改名；偷流层仅允许交接已点名的 `netdev gfc_trans`。sing-box 生成器禁止改 `auto_route` / `route.final`。

正式交付定级 **Dataplane-Arch / Major**，通道固件/人工。试编排错 **不** bump 产品号 / `PKG_RELEASE`（`VERSION_AND_RELEASE.md` §1.5）。

---

## 1. 产品定位

透明是第三种客户入向，不是整机桥接，也不是旁路的变种。

| | 网关 `gateway` | 旁路 `bypass` | 透明 `transparent` |
|--|--|--|--|
| 客户默认网关 | GFC LAN | GFC WAN IP | **不变**（仍是 ISP / 上游设备） |
| GFC 互联地址 | 要 | 要（WAN） | **不占用** 客户↔上游互联地址 |
| 客户 inbound 到 CE | NAT 后通常不是原 CE | 不做客户 SNAT | **L2 直达 CE** |
| IPsec / GRE / IKE | 过网关，易被 NAT | 三层转发 | **当电缆，不偷** |
| 管理 LAN | 可与客户同口 | 终身独立，禁桥 WAN | **同旁路：独立，禁桥** |
| 国际 TCP | 分类进 TUN | 同左 | 偷进 **同一套** inet 分类 / `0x2023 → 2022 → gfctun` |
| 递归 DNS | 劫持 + DHCP 6=LAN | 劫持 + 可问 WAN IP | 默认电缆全拦 53；关劫持后问 **DNS VIP** |

**一句话：** 默认 L2 直通；只把「要代理的国际 TCP」和「要进 unbound 的 DNS」punt 进现有三层栈；盒子本机控制面/VLESS **搭车 CE 地址**，稳态 **不抢 ARP**。

禁止用 proxy-ARP / 纯三层透明作为产品档或降级档（专线 GTSM / 单跳 BFD / 以太网 OAM / 绑 MAC 会翻车；与「插 /30」是同一类客户）。

---

## 2. 已拍板决议（禁止当未决重开）

| # | 决议 |
|---|------|
| 1 | 唯一模式：L2 电缆 + 选择性 punt。不做整机 `br-lan`+WAN 桥，不做 proxy-ARP 档。 |
| 2 | 管理 LAN 终身独立，永不与 isp/cpe 透明桥合并。管理口保留小网关。 |
| 3 | 默认 SKU **三口**：管理 / `isp_port`（上游：光猫或客户核心）/ `cpe_port`（下游客户设备）。口角色由 **设备 Web 显式指定或对调**，禁止靠猜。 |
| 4 | 插线顺序 **不是工序**。实现按学习状态机。`dual` 是稳态。 |
| 5 | **`dual` 之前可以没有隧道。** 只要 `cpe_port` 已学到真实客户，**禁止再当该 CE 的 ARP 主人**（即使之后 CPE 口短暂掉线）。 |
| 6 | 地址只 **被动学习主机**，禁止扫描、禁止把 /30 举例推广成「自动灌整段」。公网互联与 **私网互联适用同一机制**。 |
| 7 | 不把 isp 口 **硬件 MAC 改成 CPE MAC**（入站会进本机，客户变黑洞）。伪装 MAC **只改本机 TX**（及 DNS/代理回给客户的 TX）。 |
| 8 | 盒子出站源 IP = 学到的 CE；回程用 **五元组 hitch 表** punt 进本机。禁止用「高位源端口段」代替五元组（与 Windows 临时端口重叠）。 |
| 9 | 一期：国际 **TCP** 进隧道；**ESP / AH / GRE / IPIP / L2TP / UDP 500 / UDP 4500** 永不偷；其它 UDP（含 QUIC）L2 直通。 |
| 10 | 目的 RFC1918、本链路 CE/GW、`bypass_ip`、`TO_CN`（split 模式）**不偷数据**（DNS 见 §6，与此不同）。 |
| 11 | **默认劫持全部客户递归 DNS**（含目的为私网网关的 53）。**不**按「目的 RFC1918 就放行 53」。 |
| 12 | 三种 `proxy_mode` 共用设备级 **DNS 劫持开关**（只关抢包，不关 unbound）。关后客户须问 GFC 的 DNS 地址。 |
| 13 | 透明的自愿 DNS 入口 = 盒子生成的 **仅答 53 的 DNS VIP**（不是互联上的「GFC 网关」）。网关模式地址=LAN IP；旁路=WAN IP。 |
| 14 | 另提供 **不劫持目的 IP 列表**（内网权威 DNS）。全关是应急；排除列表才是类型 A/B 同时保全的正道。 |
| 15 | `bridge-nf-call-iptables` **保持关闭**。L2 直通帧不得进 inet conntrack。 |
| 16 | 用户策略 / 系统分流与网关、旁路 **同一模型**，只变入向。 |
| 17 | `proxy_mode`、DNS 劫持开关、排除列表、口角色、DNS VIP：**仅设备 Web 可写**；控制面只读上报；忽略 payload 写入。 |
| 18 | 软件失败 **fail-open**：透明桥仍转发。硬件旁路继电器为独立 SKU，非本契约。 |
| 19 | 一期 **IPv6 整帧 L2 直通**，不分类、不劫持 IPv6 DNS。PPPoE 发现/会话 L2 直通，不拆内层（独立模式另开）。 |
| 20 | 一期默认只处理 **untagged IPv4**；带 802.1Q 的帧默认 L2 直通。设备 Web 可声明「业务 VLAN」，对该 VLAN 做与 untagged 相同的偷流/DNS。 |

---

## 3. 口、桥与管理面

```
管理 LAN（现有 br-lan / 小网关）    —— 永不进透明桥
        |
      GFC
     /     \
 isp_port   cpe_port
 (上游)     (下游客户)
     \     /
    二层透明桥（无互联 IP、混杂、默认转发）

本机 CE /32 与 DNS VIP：CE 挂 veth `gfc-ce`（对端 `gfc-ce-fwd` 承接 netdev `fwd`）；VIP 挂 dummy `gfc-dns`。禁止在 isp/cpe 口对外抢 CE 的 ARP
```

- 两口盒子不做默认 SKU（管理面另走 VLAN/USB 为降级，另开需求）。  
- 透明桥 **无** 客户互联地址。  
- 管理机可继续把 GFC LAN 当小网关（国内 + 跨境），NAT 仅 `ip saddr <lan_subnet>`（与旁路相同）。

---

## 4. 学习状态机

口在透明模式中 **始终启用**，不按插线顺序 disable。

| 状态 | 条件 | 行为 |
|------|------|------|
| `idle` | 尚未学到两端有用信息 | 纯 L2 转发；不上 VLESS |
| `cpe_only` | 已学 CPE MAC 和/或 CE IP；isp 未就绪 | **绝不**冒充上游网关、不答 GW 的 ARP；等 isp |
| `isp_only` | 仅 isp 有学习结果，且 **从未** 学到真实客户 | 允许纯被动学习；**不要求**先上隧道。禁止扫描猜 CE。若产品要 WAN-only 上平台：仅在此状态可临时答 CE ARP；一旦进入过「已学到客户」则永远禁止 |
| `dual` | isp 与 cpe 均已学到 | 稳态：§5–§7 |

**已学到真实客户** 的定义：`cpe_port` 链路上观察到任一客户 MAC，或观察到任一客户 IP 的 ARP/IPv4 源（主机表非空或已有主 CE）。此后禁止再当 **任何已学电缆主机** 的 ARP 主人（不只主 CE）。

学习规则：

- **只被动**：ARP、IPv4 头、若存在则 DHCP Option 1/3/`yiaddr`。  
- **禁止** 对疑似前缀做 ARP/ICMP 扫描。  
- 学主机不学网段；不要把客户未使用的 /29 余址当成自己的。  
- **主 CE IP** = cpe 口上对非网关单播加权最高的源（正在 ARP 网关加分），或其 ARP `tell`；一旦可用则粘住，不随每帧重选。  
- **主 CPE MAC** = **该主 CE IP** 的以太网源。禁止用「cpe 口最近一帧的源 MAC」覆盖（last-writer 会在交换机多 PC 下飘）。  
- **电缆主机表** = 每个学到的客户 `IP → MAC`（timeout）；与主 CE 分开存。不得写入 inet `TO_CN` / `bypass_ip` / `ext` / `ext_const`。  
- **PE MAC / GW IP** = isp 口入向与对端 ARP。  
- **GW IP 收敛（强/弱证据）**：**强证据** = isp 口上「为主 CE 或任一已学电缆主机」发起的 ARP request，其发送方即真下一跳；DHCP Option 3 同级。**弱证据** = cpe 口 ARP request 的 `tell` 目标，仅在 GW 为空时填入，且目标若已在电缆主机表中则 **一律拒绝**（那是同网段邻居，不是网关）。强证据可改写弱证据，弱证据永不改写强证据。共享网段（实验室 vSwitch、promisc）上任意邻居的 ARP **不得**当选网关。  
- **PE MAC 冻结按 GW IP 收敛**：同一 GW IP 内首次填入后冻结，后续声称同一 GW IP 的 ARP **不得**改写（实验室双假网关 / proxy-ARP / VRRP 换 MAC 仍须邻居 FAILED 后再学或 Web 重学）；**GW IP 变更**（换网段、换上联）时清空 PE MAC 重新学习——否则盒子会一直把帧打向本网段不存在的 MAC 且无自愈路径。禁止在同一 GW IP 内改回 last-writer。  
- **主 CE 存活性（禁止用沉默计时判死）**：链路安静 **不是** 客户下线的证据，不得因「多久没收到帧」就换 CE。只认两类证据：① isp 口连续 `CEArpMissLimit`（默认 5）次 `who-has <主 CE>` 无人应答——下一跳无法投递即为死亡证明，主 CE 任一帧出现即清零；② 主 CE 超过 `CEStaleAfter`（默认 5 分钟）未出现，而电缆主机表中 **另有** 主机在该窗口内活跃。判死后从主机表删除该 IP 并在活跃主机中改选（权重优先、时间次之），无活跃主机则主 CE 置空、停止搭车。两条都不成立时维持现状。  
- 盒子出 isp 的 hitch **仍只用一个主 CE**（SNAT + TX `src MAC=主 CPE`）。`cpe` 口直挂 L2 交换机、多台 PC：不 punt 的帧仍 L2 一字不改；偷来的 DNS / 国际 TCP 回程 `dst MAC` 用主机表里该目的 IP 的 MAC，而不是全局主 CPE MAC。  
- **永不** 借用 GW/PE 地址。  
- CE DHCP 换址则热更新；过期地址停止搭车并从主机表删除。  
- 公网 /30 与私网 `10.x` 互联同一套学习。

### 4.1 主动探测（提案 · 未实现 · 待用户确认后方可写代码）

纯被动学习有两个死角：客户全程不发包时学不到 CE；换网段后 PE MAC 缺失且上联不主动说话时学不回来。补救手段 **只允许** 一种：

- **ARP Probe（RFC 5227 §2.1.1）**：`sender protocol address = 0.0.0.0`、`target hardware address = 0`、`target protocol address = 待探目标`。发送方 IP 为全零，收方 **不得** 因此建立/更新 ARP 缓存条目，故不声明任何地址、不污染任何缓存、不构成 ARP 抢占，与「已学到客户后禁止当 ARP 主人」不冲突。
- **源 MAC 只用本口硬件 MAC**；**禁止** 用主 CPE MAC 或任何伪造 MAC 发探测（那是 isp 侧重复 MAC，会污染上联 MAC 表并触发端口安全）。
- **触发条件（有因才发，禁止周期性扫描）**：① 主 CE 存活存疑（`CEArpMissLimit` 将达）时向 **cpe 口** 探主 CE；② GW IP 已知而 PE MAC 为空时向 **isp 口** 探 GW。
- **频率上限**：2 秒一次、最多 3 次，随后退避到 30 秒；目标 **只能** 是主 CE 或 GW IP，禁止遍历前缀。
- **仍然禁止**：自造 IP / 自造 MAC 上线、ICMP/TCP 扫段、对未学到的地址试探。

无客户时的管理面上线，**不得** 用自造地址解决；如需该能力，走「运维显式配置的备用管理 IP（isp 网段空闲地址 + 掩码 + 网关，仅在未学到主 CE 时启用）」，唯一性由运维保证——另行立项，本节不含。

---

## 5. ARP 与 MAC

### 5.1 ARP 主人

| 阶段 | 谁答已学电缆主机的 ARP |
|------|----------------|
| 从未学到客户的 `isp_only`（可选 WAN-only） | 盒子可临时答主 CE |
| 已学到客户之后（含 `dual`、CPE 口后掉线） | **只有客户**；盒子禁止答、禁止 GARP 抢占 **任一已学主机** |

稳态：入站访问这些主机（含对端 IPsec）L2 给对应客户 MAC。非主 CE 的 `/32` 只做 on-link 路由与邻居，**不**配成本机地址。

### 5.2 MAC 伪装（仅 TX）

| 方向 | 改写 |
|------|------|
| 本机出 isp（VLESS / 心跳 / unbound 国际上游） | `src MAC = 主 CPE MAC`，`dst MAC = PE MAC`，`src IP = 主 CE` |
| DNS 应答 / 代理回程出 cpe | `src MAC = PE MAC`，`dst MAC = 该目的 IP 在主机表中的 MAC`（netdev map `host_mac`）；表未命中时才回退主 CPE MAC |
| 客户原有帧 | **一字不改** L2 转发 |

禁止把 isp 口烧录/内核 MAC 设成 CPE MAC。

---

## 6. DNS（含三种模式共用开关）

拆解析 **始终** 由 unbound 做。劫持只保证「发给别人的 53」也会进 unbound。

### 6.1 默认：劫持客户递归 DNS

对当前模式的 **客户入向**，默认拦截 UDP/TCP **53**（含目的为私网网关、114、8.8.8.8 等）。

透明应答必须 **源 IP = 客户原来问的解析器**，源 MAC = PE；禁止网关式 `redirect` 把源变成盒子/127.0.0.1（客户问的是 10.50.0.1 或 8.8.8.8）。

**不要** 用「目的 RFC1918 则放行 53」：私网网关当 DHCP Option 6 是最常见递归入口，放行则国际污染无解。

内网权威 DNS（AD / Hub）仅当查询 **穿过 GFC** 才会被误伤。多数 AD 在 CPE 后 LAN 上，包不到透明电缆。

### 6.2 设备级开关 `dns_hijack`

| 项 | 规则 |
|----|------|
| 范围 | `gateway` / `bypass` / `transparent` **同一开关** |
| 默认 | **on** |
| 写入 | 仅设备 Web；控制面只读 |
| on→off | 去掉「抢发给 **非 GFC DNS 监听** 的 53」；**unbound 不停**；网关 DHCP 6 不改 |
| 透明 + off | 电缆上不再全拦 53；仍须 punt **目的=DNS VIP 且 53** |
| 网关 + off | 去掉 LAN `gfc_dns_hijack` redirect；主机直问 LAN IP:53 仍进 unbound |
| 旁路 + off | 去掉 WAN 上对 `customer_hosts` 的 53 redirect（本机目的 skip 逻辑仍防环）；客户直问 WAN IP:53 仍进 unbound |
| 隧道未就绪 | 透明 53 **fail-open**（不拦死），避免安装窗口无 DNS |

关闭劫持 **不是** 改走 ISP DNS。文案须写清：关了以后，想无污染必须把递归 DNS 指到 GFC 的 DNS 地址。

### 6.3 不劫持目的列表 `dns_hijack_exclude`

设备 Web：IPv4 列表。发往这些地址的 53 **不抢**（内网权威 / 穿过盒子的 Hub DNS）。默认空。  
排除后，客户递归仍应走 114/网关/GFC，默认劫持继续覆盖类型 A。

全关是排除不够时的应急，不要当作企业内网的唯一工具。

### 6.4 透明 DNS VIP

透明稳态 **没有** 客户可填的互联网关 IP。关劫持或客户自愿指定 GFC DNS 时：

| 项 | 规则 |
|----|------|
| 形态 | 盒子生成的 **仅用于 DNS 的 IPv4 /32** |
| 默认 | `172.31.253.53/32`（GFC 保留；**禁止** 使用 `198.18.0.0/15`，与 fake-ip 冲突） |
| 持久 | 跨重启稳定；冲突或 Web 改写后落盘 |
| 冲突 | 与管理 LAN CIDR、学到的 CE/GW、WAN IP、`customer_hosts` 重叠则在 `172.31.253.0/24` 另选主机；耗尽则 `172.31.252.0/24` |
| 覆盖 | 设备 Web 允许在保留池内改；客户内网若占用该段须手改（盒子看不见 CPE 后 LAN） |
| 挂载 | dummy，**不** 配在 isp/cpe 口；**不** 为 VIP 在互联上抢与 CE 冲突的 ARP |
| 可达 | 靠客户默认路由把 VIP 发向电缆；GFC 在 cpe 入向按 `daddr=VIP dport=53` punt（即使 `dns_hijack=off`） |
| 展示 | 设备 Web 明确展示「GFC DNS 地址」供客户填 Option 6 / WAN DNS |
| ACL | 主 `server:` 已允许 RFC1918（`10/8` `172.16/12` `192.168/16`）及 `127/8`。私网互联上的多台 PC **不必** 在 extra 文件逐台列举，也 **禁止** `0.0.0.0/0 allow`（WAN/isp 上能打到 `:53` 的源会变成开放解析器）。公网互联：`gfc-bypass-acl.conf` 为每个学到的 **公网** 电缆主机写 `/32 allow`。 |

网关 / 旁路 **不必** 另造 VIP：DNS 地址分别是 LAN IP / WAN IP。

### 6.5 非目标（DNS）

- 一期不拦 DoH / DoT（443 / 853）。  
- 不改 unbound 国内/国际 `forward-zone` 语义来迁就透明。  
- 透明劫持实现须走 trampoline / TPROXY / `snat to ct original daddr` 一类 **源伪装**；禁止用会暴露盒子地址的裸 `redirect` 当透明 DNS。

---

## 7. 偷流与本机搭车

`bridge-nf` 关闭。仅 punt 后的包进 inet `gfc`（现有链/mark）。

### 7.1 cpe 口入向（客户→上游）

顺序（先匹配先定）：

1. 非 untagged IPv4（除非 Web 声明了该业务 VLAN）→ L2  
2. IPv6 / PPPoE / 非 IP → L2  
3. ESP / AH / GRE / IPIP / L2TP / UDP 500 / 4500 → L2  
4. 目的为本链路 **任一已学主机**/GW、RFC1918、`bypass_ip`、split 下 `TO_CN` → L2（**53 除外**，53 走 §6）  
5. UDP/TCP 53：按 §6（劫持 on、排除列表、VIP）  
6. TCP 且目的国际（须代理）→ punt → `prerouting_mangle_ct` 等现有分类 → `0x2023` → `gfctun`  
7. 其余 → L2  

用户 Override / `usr_*` 在 punt 进 inet 之后按 `USER_POLICY_ROUTING.md` 裁决。未 punt 的帧 **看不到** 用户策略（与「只变入向」一致）。

### 7.2 isp 口入向（上游→客户）

1. 五元组命中 **hitch_reply**（本机出站回程）→ punt 本机  
2. 其余 → L2 给 CPE  

公网打 CE、对端 IPsec，只要不在 hitch 表，必须给客户。

### 7.3 本机出站搭车

- 源 IP = **主** CE（SNAT 或 bind 在 dummy /32）；本机 **禁止** 对已学电缆主机发 ARP。每个学到的客户 IP 在 `br-trans` 上有 on-link `/32`（**不**进 `local`、**不**把非主 CE 配成本机）。netdev `host_mac` 在 `in_cpe` 入向刷新；`eg_trans` 命中则 `src MAC=PE`、`dst MAC` 查表并 `accept`，禁止把「目的是另一台 PC」的回程当成互联网 hitch 打向 PE。  
- 邻居：GW IP → PE MAC 写死在 isp 口。  
- POP 等基础设施仍在 `bypass_ip`，避免 VLESS 再被偷进 TUN。`output_mangle_route` 对目的 `@bypass_ip` **必须清掉** `0x2023`（在 `meta mark != 0 return` 之前）。仅清 skb mark 不够：透明 VLESS 省略 `bind_interface` 时，套接字 `SO_MARK=0x2023` 在 nft 之前查 FIB，必须另有 `ip rule pref 90 to <bypass_ip> lookup main`（及 table `2022` 的 `/32` 搭车路由），否则 `:8443` 进 `gfctun`。FIB 走 `br-trans` 之后，本机帧在桥上 `xmit`：必须在 **`eg_trans`（device br-trans）** 记 hitch。目的 **不是 CE** 的才改成 CPE 源 MAC + PE 目的 MAC（VLESS 出 isp）；目的 **是 CE** 的是 DNS/trampoline 回客户，必须改成 PE 源 MAC + CPE 目的 MAC（出 cpe）。禁止把回给 CE 的包改成 PE 目的 MAC（下联 DNS 会超时）。`eg_isp` 仅对 `ether saddr != CPE MAC` 记 hitch。电缆 DNS inet DNAT 必须覆盖 **iif cpe**（MAC-punt 后查询常从 cpe 奴口上栈）。`inet nat postrouting` 对 **udp/tcp sport 53 必须 `return`，再** 做 hitch `snat to CE`；否则应答源变成 CE、目的也是 CE，下联当 martian 丢掉。CE `/32` 在 `br-trans` 必须 `src <dns_vip>`；trampoline（`snat to ct original ip daddr`）在 original daddr 已是 CE 时必须跳过。hitch 回程命中 `hitch_reply` 后只负责 punt；原本机源地址由同一 conntrack 的 reverse-SNAT 自动恢复。**禁止**再按 `daddr=CE` 添加手工 prerouting DNAT：它会与 reverse-SNAT 竞争，并可能改写不属于本机的客户入站流量。
- 私网 CE：上游设备继续 NAT/路由；GFC 不另要公网地址。  
- 在 OUTPUT/SNAT 后写入 hitch 回程五元组（超时跟随连接）。

### 7.4 代理回程

`gfctun` 出来目的为 CE 的客户流：从 **cpe 口** 送出（封装如 §5.2）。`rp_filter` 在透明相关口为 loose（`2`）。

---

## 8. 与现有数据面咬合

```
电缆帧
 ├─ 不 punt → 透明桥 L2 出去
 └─ punt → inet PREROUTING（现有 gfc 链）→ 用户策略 / TO_CN / mark
              └─ 国际：0x2023 → table 2022 → gfctun

GFC 本机 OUTPUT → SNAT CE + TX 改 MAC → isp
管理机：LAN 小网关（旁路同款 NAT 限制）
```

- **不改** 默认 mark、hook 优先级、`route.final`、`auto_route`。  
- Client sing-box：透明省略 `bind_interface`。`route.default_interface`：**仅** MAC-punt（透明且 `br-trans` 存在、**无** `gfc-ce`/`gfc-ce-fwd`）为该桥；veth 产品路径 **省略**（禁止绑 `br-trans` / `gfctun` / isp 从口 / `gfc-ce`）。网关/旁路仍为 WAN。切模式必须对齐残留 JSON（`AlignBindWithProxyMode`）。禁止全局写死 `br-trans`。详见 [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md) 与 09-16 交接。  
- 偷流所用 **bridge / netdev 表名、链名** 实现前 **不得擅自写入生成器**；须先差异表，用户确认后 **先登记 `NFT_ARCHITECTURE.md` 再写代码**。  
- 禁止发明与 `nat` / `gfc_dns_hijack` / `gfc` 冲突的 inet 表替换骨架。  
- OEM 必须含 `kmod-veth`。无模块时的 MAC-punt + `tc skbedit` 是回退，不是产品默认偷流 RX。

---

## 9. 控制面与 UI

| 项 | 规则 |
|----|------|
| `proxy_mode=transparent` | 一期已开放；仅设备 Web 可写；切换须确认超时回滚（对齐旁路） |
| 口角色 isp/cpe | 设备 Web |
| `dns_hijack` / `dns_hijack_exclude` / DNS VIP | 设备 Web |
| 平台 | 只读展示已确认模式与开关；payload **不得** 开局写入 |
| 策略路由 UI | 透明可与网关/旁路共用；试算须返回 `ingress_eligible`（例如尚未 `dual`） |

---

## 10. 绝对禁止

- 管理 LAN 与 isp/cpe 桥接  
- proxy-ARP / 把 TTL-- 的三层透明当产品模式  
- 为 CE 在 `dual`（或已学到客户）后应答 ARP  
- 扫描猜地址；冒充 GW/PE  
- 国际 UDP 一期进隧道（易误伤 IPsec NAT-T）  
- 学习 IP 写入 `TO_CN` / `bypass_ip` / `ext` / `ext_const`  
- 客户电缆流量 WAN SNAT  
- `access-control: 0.0.0.0/0 allow`（私网多 PC 已由主 `server:` RFC1918 覆盖，不要用开放解析器代替主机表）  
- MosDNS / sing-box DNS inbound 替代 unbound  
- 因透明改 kernel-split `auto_route` / `route.final`  
- 把 `route.default_interface` 全局写死为 `br-trans`（网关/旁路必须仍是 WAN）  
- 切离透明后不恢复 WAN `bind_interface` / WAN `default_interface`  
- `bridge-nf-call-iptables=1` 作为偷流捷径  
- 用源端口段代替 hitch 五元组  
- 关劫持时关掉 unbound  
- 试编 bump `PKG_RELEASE` / 产品 tag  
- 未「确认修改」就改 nft/unbound/sing-box 生成器或擅自登记新表名进运行时

---

## 11. 验收提纲（实现后）

```sh
# 模式与口
# proxy=transparent；isp/cpe 角色正确；管理 LAN 不在透明桥
bridge link    # 或等价：isp 与 cpe 同桥，br-lan 不在其中

# ARP：dual 下盒子不对 CE 答 ARP
ip neigh show
# 公网/上游访问 CE 仍到客户设备；IPsec 过电缆

# 国内 TCP / RFC1918：L2，TTL 不变（对端 traceroute 不显示 GFC 跳）
# 国际 TCP：进 gfctun；nft 现有 mark 0x2023
ip rule | grep 0x2023

# DNS 劫持 on：CE→114 或 CE→私网网关:53 的应答源仍为原目的，内容为 unbound 拆解析
# DNS 劫持 off：上述不再抢；CE→DNS VIP:53 仍进 unbound
nft list table inet gfc_dns_hijack   # 网关/旁路开关可见；透明另有 punt 规则（表名以当时 NFT_ARCHITECTURE 为准）

# 本机 VLESS：源 IP=主 CE，源 MAC=主 CPE；回程命中 hitch，不送到 CPE

# 多 PC（cpe 直挂交换机）：两台同时问被劫持的 53，各自收到应答（邻居不是对方 MAC）
```

抓包：IPsec 不得进 inet ct；DNS 回包不得从 `gfctun` 出给客户（除非该 DNS 本身走国际上游的是 **盒子→上游** 而非客户应答路径）。

---

## 12. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-09-16 | 学习收敛：GW 强/弱证据（isp 为本侧主机 ARP = 强；cpe `tell` = 弱且不得选中已学主机）；PE 冻结按 GW IP 收敛，换网段清空重学；主 CE 存活性只认「PE 连续 ARP 无应答」或「自身过期且他机新鲜」，禁止沉默计时判死。新增 §4.1 ARP Probe 提案（未实现）。`host_mac` timeout 必须写 key 侧（nft 1.1.1 拒绝值侧 timeout）。 |
| 2026-09-16 | cpe 直挂交换机多 PC：电缆主机表 IP→MAC；偷流回程按主机；搭车仍一个主 CE；停 CPE last-writer。私网 DNS ACL 用既有 RFC1918，禁止 `0.0.0.0/0`。试编不升号。 |
| 2026-09-16 | veth runtime 里程碑：探测口 `gfc-vp0`/`gfc-vp1`；透明+veth 省略 `default_interface`；`LiveMode` 已确认 JSON 盖过 stale env；PE MAC freeze。研发 tag `milestone/transparent-veth-runtime-20260916`，不升产品号。 |
| 2026-09-15 | 实验室闭环：CPE DNS（VIP + 劫持 53）；CE `/32` `src` DNS VIP；trampoline 跳过 original daddr=CE；无 veth 时 MAC-punt + `tc skbedit`。sing-box 透明 MAC-punt 时 `default_interface=br-trans`，切模式 Align JSON。OEM 必须含 `kmod-veth`。 |
| 2026-09-15 | hitch 回程仅 punt；由 conntrack 自动 reverse-SNAT，删除手工 daddr-CE DNAT |
| 2026-09-14 | hitch SNAT 不得覆盖 sport 53 |
| 2026-09-11 | punt 口：`gfc-ce`/`gfc-ce-fwd` veth（`nft fwd` 必须进 RX）；`gfc-dns` 仍 dummy |
| 2026-09-09 | 一期合入：`netdev gfc_trans`；设备 Web 开放 `transparent`；确认/回滚对齐旁路 |
| 2026-08-31 | 讨论冻结：L2+punt、禁 proxy-ARP、状态机与 ARP 让权、默认全拦 53、跨模式劫持开关、DNS VIP、私网互联同机制 |
