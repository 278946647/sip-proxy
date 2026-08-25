# GFC 会话交接（HANDOFF）

> 写给**完全没有上下文**的新对话。  
> 最后更新：**2026-08-25**  
> 仓库：`sip-proxy`（`gfc-platform/` 控制平台 + `gfc-client/` ImmortalWrt 客户端）  
> **当前主线：旁路模式已实现并联调通过（含公网 customer_hosts DNS）。**

---

## 0. 新会话 30 秒开场

```
读 HANDOFF.md + docs/BYPASS_MODE.md；
严格按 docs/NFT_ARCHITECTURE.md §9.3 Option B 与 UNBOUND §4.1；
数据面改前先差异表，等「确认修改」后再改点名文件；
proxy_mode 仅设备 Web 写；控制面只读（API 拒绝写入为后续任务）；
@customer_hosts 可为公网；禁止自动灌整个 WAN 前缀；
OEM 默认 LAN 暂不改；试编不升号（§1.5）。
```

| 文档 | 用途 |
|------|------|
| [`docs/BYPASS_MODE.md`](docs/BYPASS_MODE.md) | 旁路 **产品契约** |
| [`docs/NFT_ARCHITECTURE.md`](docs/NFT_ARCHITECTURE.md) | nft 唯一真相 |
| [`docs/UNBOUND_ARCHITECTURE.md`](docs/UNBOUND_ARCHITECTURE.md) | LAN/旁路 DNS |
| [`docs/SINGBOX_ARCHITECTURE.md`](docs/SINGBOX_ARCHITECTURE.md) | kernel-split；不随 proxy_mode 改 final |
| [`docs/VERSION_AND_RELEASE.md`](docs/VERSION_AND_RELEASE.md) | 发版 |
| [`gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md`](gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md) | **仅固件 OEM 构建** |

---

## 1. 已完成（禁止当未做重开）

- Option B nft：WAN + `@customer_hosts` 打标/分类/DNS 劫持；客户无 WAN SNAT；LAN 小网关
- 设备 Web 切模式 + 超时回滚；客户端忽略控制面 `proxyMode` 写入
- 旁路保留 `0x2023 → 2022 → gfctun`
- 公网客户：OUTPUT `daddr @customer_hosts return` + unbound `gfc-bypass-acl.conf`
- 联调：旁路可工作（用户 2026-08-25 确认）

**未做 / 刻意冻结**

- `transparent` 未开放
- 平台 REST 仍可能写 DB `proxy_mode`（文档：只读；API 拒绝为后续）
- ImmortalWrt OEM 默认 LAN **不改**（常见 `192.168.1.0/24`）
- 进 OEM 镜像的正式数据面发版（Dataplane-Arch / Major）

回滚实现前 1.x 快照：`git checkout v1.1.9`。当前产品 **v2.0.0**（`gfc-client 2.0.0-r1`）；试编仍不额外升号（§1.5）。

---

## 2. 踩过的坑

| 坑 | 正确做法 |
|----|----------|
| 旁路 = 关策略路由 | 国际仍要 mark→TUN |
| WAN 一律 ct mark | 方案 A 已否决 |
| 只劫持 LAN DNS | 必须 WAN+customer |
| 客户 WAN masquerade | 国内回程打环 |
| 假定客户是 RFC1918 | `@customer_hosts` 可公网；OUTPUT+unbound ACL 必须认集合 |
| 自动灌 WAN `/24` 进 hosts | 公网邻居误伤 |
| 控制面开局切旁路 | 仅设备 Web |
| `verify` 用 `nft list table inet nat postrouting` | 用 `nft list chain inet nat postrouting`；旁路须 `ip saddr <lan>` |
| 用 `docs/draft/*` 或 `GATEWAY_CORE` 旁路表当权威 | `BYPASS_MODE.md` + `*_ARCHITECTURE.md` |

---

## 3. 关键代码锚点

```
docs/BYPASS_MODE.md
gfc-client/internal/proxymode/
gfc-client/deploy/immortalwrt/gfc-routing.sh
gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
gfc-client/internal/render/unbound/unbound.go
```
