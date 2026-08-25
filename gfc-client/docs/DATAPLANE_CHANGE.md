# GFC Client — 底层数据面变更与验收规范

> **范围**: DNS（unbound/dnsmasq）、nft（gfc-routing）、sing-box、网络 apply、bootstrap/upgrade  
> **原则**: 动底层必先对照架构文档出差异表，验收不过不得算完成

---

## 1. 权威文档（优先级）

| 层级 | 文档 |
|------|------|
| nft | `docs/NFT_ARCHITECTURE.md` |
| DNS | `docs/UNBOUND_ARCHITECTURE.md` |
| 旁路 | `docs/BYPASS_MODE.md` |
| sing-box | `docs/SINGBOX_ARCHITECTURE.md` |
| WAN apply | `gfc-client/docs/NETWORK_APPLY.md` |
| 远程运维 | `gfc-platform/docs/REMOTE_ACCESS.md` |

Cursor 规则：`.cursor/rules/*-no-change-without-approval.mdc` + `dataplane-bottom-layer.mdc`

---

## 2. 变更前（强制）

修改以下路径前 **必须先输出「规范 vs 当前实现」差异表**，等用户 **「确认修改」**：

- `gfc-client/internal/render/**`
- `gfc-client/internal/network/**`
- `gfc-client/deploy/**/gfc-routing.sh`
- `gfc-client/deploy/immortalwrt/**`
- `gfc-client/share/unbound/**`
- `docs/*_ARCHITECTURE.md`

差异表至少包含：

1. 影响面（LAN DNS / NAT / 分流 / WAN / 远程隧道）
2. 修改文件列表
3. 与权威文档不一致项
4. 设备验收命令

---

## 3. LAN 上网数据路径（验收心智模型）

```
下联 PC
  → DHCP option 6 = 网关 LAN IP
  → DNS 查询网关:53
  → gfc-unbound（:53 必须监听）
  → nft gfc_dns_hijack（外连 DNS 重定向 :53）
  → nft nat masquerade（WAN 出口，gfc-routing 必须应用）
  → 国内 IP 直连 WAN / 国际 mark → gfctun → sing-box（已激活时）
```

**任一环断裂 → 下联无法打开网页或仅部分站点可用。**

---

## 4. 常见故障链（本次事故归纳）

| 现象 | 根因 | 检查 |
|------|------|------|
| 全网打不开 | `gfc-unbound` 未监听 :53 | `pidof unbound`, `drill @网关 baidu.com` |
| 全网打不开 | bootstrap 失败，snippet/include 缺失 | `unbound-checkconf`, `ls /etc/unbound/local.d/` |
| 能 ping 不能上网 | `gfc-routing` 未跑，无 masquerade | `nft list table inet nat` |
| 下联断流/部分不通 | **fw4 与 GFC nft 冲突** | `/etc/init.d/firewall enabled` 应为否 |
| 仅国外站失败 | sing-box/TUN/策略路由 | `ip link show gfctun`, `gfc-sing-box status` |
| PC 无 DNS | dnsmasq `port=0` 但缺 option 6 | `uci show dhcp.lan.dhcp_option` |

### 4.1 bootstrap 与 gfc-routing 解耦

- **错误模式**：仅当 `sing-box.json` 存在才启动 `gfc-routing` → bootstrap 失败时 **连 NAT/DNS 劫持都没有**。
- **正确模式**：`gfc-routing` 始终先应用 **NAT + DNS hijack**；`gfc-sing-box` 仅在配置存在时启动。

### 4.3 ImmortalWrt fw4（stock firewall4）

GFC **不**使用 UCI `firewall` / fw4 管理转发。`gfc-routing.sh` 安装 `inet nat` / `inet gfc` / `inet gfc_dns_hijack`。

| 项 | 要求 |
|----|------|
| `/etc/init.d/firewall` | **stop + disable** |
| 脚本 | `deploy/immortalwrt/disable-immortalwrt-fw4.sh` |
| `apply-network` | 不得 `restart firewall`（会重新拉起 fw4） |

安装/升级、`gfc-routing start`、`apply-network` 后自动执行 disable。

### 4.4 unbound include 文件

`unbound.conf.template` 引用的文件 **必须在 bootstrap 时存在**：

- `/etc/unbound/conf.d/gfc-domestic-forward.conf`
- `/etc/unbound/local.d/gfc-block.conf`
- `/etc/unbound/local.d/gfc-static.conf`

来源：`share/unbound/**` + `EnsureTree()` + `ensure-unbound-dirs.sh`

---

## 5. 标准验收脚本

安装/升级末尾自动执行：

```sh
sh /usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
```

手动全量检查：

```sh
# 服务
/etc/init.d/gfc-unbound status
/etc/init.d/gfc-routing status
pidof unbound

# DNS
unbound-checkconf /etc/unbound/unbound.conf
drill @$(uci get network.lan.ipaddr) baidu.com +short
netstat -uln | grep ':53 '

# DHCP DNS 下发
uci show dhcp.@dnsmasq[0].port    # 0
uci show dhcp.lan.dhcp_option     # 含 6,<LAN网关>

# NAT / 劫持
nft list table inet gfc_dns_hijack
nft list table inet nat
/etc/init.d/firewall enabled   # 应返回 disabled

# 下联 PC：ipconfig /all 看 DNS 是否为网关
```

---

## 6. 设备快速修复（下联不能上网）

```sh
sh /usr/lib/gfc-client/deploy/immortalwrt/ensure-unbound-dirs.sh
GFC_PLATFORM=immortalwrt gfc-bootstrap
unbound-checkconf /etc/unbound/unbound.conf

/etc/init.d/gfc-unbound restart
/etc/init.d/gfc-routing start
sh /usr/lib/gfc-client/deploy/immortalwrt/disable-immortalwrt-fw4.sh
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-dnsmasq-dhcp.sh
/etc/init.d/dnsmasq restart

sh /usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
```

下联 PC：`ipconfig /renew`（Windows）或重连 Wi‑Fi。

---

## 7. 用户固定口令

> 严格按 `DATAPLANE_CHANGE.md` 与 `*_ARCHITECTURE.md`，只改我点名的文件，改前先给差异表，我确认后再写代码；改后必须跑 `verify-dataplane-dns.sh`。
