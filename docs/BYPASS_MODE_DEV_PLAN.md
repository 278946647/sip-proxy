# 旁路模式（proxy_mode=bypass）开发计划

> **状态：** 规范已批准（2026-08-20）；**代码未实现**  
> **权威 nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) §9.1–§9.3（Option B）  
> **交接：** 仓库根 [`HANDOFF.md`](../HANDOFF.md)  
> **回滚基线 tag：** `v1.1.9`（发版存档；实现前功能快照）

---

## 1. 已拍板决议（不得在实现中擅自改口径）

| # | 决议 |
|---|------|
| 1 | WAN 打标策略 = **Option B**：`iif WAN` + `saddr @customer_hosts` + daddr 分类；禁止 WAN 全量新连接 ct mark |
| 2 | `@customer_hosts` 由 **设备 Web** 录入（开局权威）；控制面只读上报，不参与开局写入 |
| 3 | DNS 劫持：**不能只沿用 LAN**；必须加 WAN + `@customer_hosts` 四条（local return ×2 + redirect ×2） |
| 4 | 客户侧 **不做 WAN SNAT**；管理 LAN **保留小网关**（LAN 分类 + `ip saddr <lan_subnet>` masquerade） |
| 5 | `proxy_mode` **仅设备 Web 可写**；切换后走单一编排 apply；**超时未确认则回滚** |
| 6 | LAN 永远独立管理网，禁止与 WAN 桥接 |
| 7 | 旁路必须开启策略路由 `0x2023 → 2022 → gfctun`（现行「bypass 关 mangle」视为 bug） |
| 8 | 表/链名/hook/mark/`output_mangle_route` 与网关一致，只改匹配条件 |

---

## 2. 实施阶段（建议顺序）

### P0 — 文档与契约（本会话）

- [x] `NFT_ARCHITECTURE.md` §9.3 Option B
- [x] 本开发计划 + `HANDOFF.md`
- [x] 产品存档 tag `v1.1.9`

### P1 — 设备 Web：模式切换 UX + 本地配置

目标文件（实现时由用户点名后再改）：

- LuCI / Vue：`proxy_mode` 切换页（旁路时强制 IP/掩码/网关 + `customer_hosts`）
- 本地持久化：如 `/etc/gfc-client/network-wan.json`、`customer-hosts.json`、`proxy_mode`
- API：仅本机 Web 写模式；拒绝控制面强制写旁路（或忽略）

验收：

- 缺 `customer_hosts` 不能切 bypass
- 切换提示从 LAN 口操作
- 超时未确认回滚 WAN + 模式

### P2 — 编排 apply（幂等事务）

- 单一入口（如 `apply-proxy-mode` / 扩展现有 bootstrap network apply）
- 分支：gateway vs bypass 生成 nft / DNS / NAT / sysctl / dnsmasq / policy routing
- 失败整单回滚；禁止半套状态

### P3 — nft / DNS / NAT 生成器对齐 §9.3

候选（须「确认修改」后只改点名文件）：

- `gfc-client/deploy/immortalwrt/gfc-routing.sh`
- `gfc-client/deploy/lib-unbound-nft.sh`
- `gfc-client/deploy/apply-network.sh` / `lib-policy-routing.sh`
- 相关 Go network manager（若 ImmortalWrt 路径走 UCI）

验收探针：

```sh
nft list set inet gfc customer_hosts
nft list table inet gfc_dns_hijack   # 含 WAN+customer
nft list table inet nat             # 仅 lan_subnet masquerade
ip rule | grep 0x2023               # bypass 下必须存在
```

### P4 — 联调与文档收口

- 国内 hairpin（`rp_filter=2`）
- 国际 TUN / VLESS
- 管理 LAN 小网关自测
- 更新 `GATEWAY_CORE.md` 中「bypass 关策略路由」过时表
- 正式含固件交付时再定级 **Dataplane-Arch / Major 或约定通道**（不得假装普通 OTA Patch）

---

## 3. 明确不做（本迭代）

- 控制面远程强制切旁路作为开局路径
- WAN 静态与 DHCP「自动探测抢默认路由」作为救命索（救命靠 LAN + 超时回滚）
- 客户 WAN 全量 masquerade
- 新表/新链名/改 mark/改 hook
- 用 MosDNS / sing-box DNS inbound 替代 unbound

---

## 4. 新会话开场白（复制即用）

> 读 `HANDOFF.md` 与 `docs/BYPASS_MODE_DEV_PLAN.md`；严格按 `docs/NFT_ARCHITECTURE.md` §9.3 Option B。旁路实现先给差异表，等我「确认修改」后再改我点名的文件。模式切换仅设备 Web；`@customer_hosts` 本地录入。回滚基线 tag `v1.1.9`。
