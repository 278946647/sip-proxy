# GFC 旁路模式（`proxy_mode=bypass`）产品与数据面契约

**Status:** 已实现并经设备联调（含公网 `customer_hosts` DNS）。  
**权威 nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) §9.1–§9.3 Option B  
**权威 DNS：** [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) §4.1  
**权威 sing-box：** [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)（kernel-split **不随** `proxy_mode` 改 `route.final`）  
**实现前基线 tag：** `v1.1.9`  
**首个可运行发版 tag：** `v2.0.0`（`gfc-client 2.0.0-r1`）  
**历史开发清单：** [`BYPASS_MODE_DEV_PLAN.md`](BYPASS_MODE_DEV_PLAN.md)（已冻结，以本文为准）

若生成器或旧文档与本文 + `*_ARCHITECTURE.md` 冲突，**以架构文档与本文为准**。

---

## 1. 产品定位

旁路不是「关掉代理的直通」。它与网关模式共用同一套数据面（表/链/hook/mark/`0x2023 → 2022 → gfctun`），只改变 **用户流量入口**：

| | 网关 `gateway` | 旁路 `bypass` |
|--|----------------|---------------|
| 客户入向 | 管理/业务 LAN（`iif LAN`） | WAN，且 `ip saddr @customer_hosts` |
| 管理 LAN | 客户网 + 管理网可同段 | **终身独立**；禁止桥到 WAN；保留小网关 |
| 客户 NAT | `oif WAN masquerade` | **禁止**客户 WAN SNAT；仅 `oif WAN ip saddr <lan_subnet> masquerade` |
| 国际出口 | 打标进 TUN | 同样打标进 TUN（不得关策略路由） |

`transparent`：**未开放**，设备 Web 必须拒绝。

---

## 2. 强制决议

| # | 决议 |
|---|------|
| 1 | **Option B**：WAN 仅当 `saddr @customer_hosts` 才 ct mark / 分类 / DNS 劫持。禁止 WAN 全量新连接 mark。 |
| 2 | `@customer_hosts` 仅 **设备 Web** 录入。可为私网或 **公网**。≠ 控制面下发。≠ 自动等于旁路 WAN 掩码（禁止把整个公网 `/24` 自动灌进集合）。 |
| 3 | DNS：LAN 两条劫持保留 + WAN customer local-return×2 + redirect×2。解析仍走 unbound `:53`。 |
| 4 | 客户不做 WAN SNAT；管理 LAN 小网关受限 masquerade。 |
| 5 | `proxy_mode` **仅设备 Web 可写**。控制面 **只读上报**；平台 API 若仍接受写入，客户端必须忽略（后续可改 API 拒绝，本迭代只定文档）。 |
| 6 | LAN 永不与 WAN 桥接。 |
| 7 | 旁路必须保持 `fwmark 0x2023 → table 2022 → gfctun`。旧文「bypass 关 mangle」视为 **bug**。 |
| 8 | 表/链/hook/默认 mark 与网关相同。匹配条件按入口变化。旁路 `output_mangle_route` **额外** `ip daddr @customer_hosts return`（本机 DNS/ICMP 回给公网客户不得进 `gfctun`）。 |
| 9 | unbound 旁路 ACL 仅来自 `customer-hosts.json`（`/etc/unbound/conf.d/gfc-bypass-acl.conf`）。禁止 `0.0.0.0/0 allow`。 |
| 10 | 切换：校验 → 单一 apply → **超时未确认则回滚** WAN + 模式 + nft。须从 **管理 LAN** 操作。 |
| 11 | ImmortalWrt **OEM 默认 LAN 维持 UCI/出厂段**（常见 `192.168.1.0/24`）。Go/Ubuntu 回退 `192.168.68.0/24` 不是盒子上的生效值。旁路冲突校验以 **设备当前 LAN CIDR** 为准。 |

---

## 3. `@customer_hosts` 怎么填

填写 **把 GFC 旁路 WAN IP 当默认网关的客户源**（主机或 CIDR），不是 GFC 自己的 WAN IP。

- 与客户内网同段：可填该网段或其中部分主机。
- 公网 WAN：必须把实际客户公网 IP/网段写入集合；系统不得因为「不是 RFC1918」就拒绝或把回包送进 TUN。
- 与管理 LAN CIDR 重叠 → 拒绝切换。
- 与旁路 WAN 前缀重叠（管理 LAN vs WAN）→ 拒绝切换。

---

## 4. 控制面

| 方向 | 要求 |
|------|------|
| 设备 → 平台 | 心跳上报已确认的 `proxy_mode`（及 hosts 若协议已有字段） |
| 平台 → 设备 payload `proxyMode` | **不得**作为开局写入；客户端忽略 |
| 平台 UI | 只展示，不提供切旁路 |
| 平台 REST 仍可能写入 DB | **文档口径：只读**；改 API 拒绝为后续任务 |

---

## 5. 实现锚点

```
gfc-client/internal/proxymode/          # 校验、pending、回滚
gfc-client/internal/api/proxymode.go
gfc-client/deploy/immortalwrt/gfc-routing.sh
gfc-client/deploy/gen-nft-policy.py
gfc-client/deploy/lib-unbound-nft.sh
gfc-client/share/unbound/unbound.conf.template   # include gfc-bypass-acl.conf
LuCI settings.js                        # 设备 Web 表单
```

含固件正式交付：定级 **Dataplane-Arch / Major**，通道固件/人工，不得假装普通 OTA Patch。试编不升产品号（`VERSION_AND_RELEASE.md` §1.5）。

---

## 6. 验收

```sh
# 模式
# proxy=bypass；customer_hosts 含实测客户源（可公网）
nft list set inet gfc customer_hosts
nft list chain inet gfc output_mangle_route   # 须有 ip daddr @customer_hosts return
nft list table inet gfc_dns_hijack            # WAN + customer 四条
nft list chain inet nat postrouting           # masquerade 含 ip saddr <lan>
ip rule | grep 0x2023
sysctl net.ipv4.conf.all.rp_filter            # 旁路期望 2
cat /etc/unbound/conf.d/gfc-bypass-acl.conf   # 客户源 allow，无 0.0.0.0/0
sh /usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
```

抓包：客户 DNS 回包应从 **WAN Out**，不得 `gfctun Out` + unbound Refused。
