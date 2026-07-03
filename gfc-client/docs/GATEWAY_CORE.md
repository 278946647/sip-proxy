# GFC Client Gateway Core（内核策略路由版）

> **nft 规则以 [`docs/NFT_ARCHITECTURE.md`](../../docs/NFT_ARCHITECTURE.md) 为准。** 本文档描述数据流与运维；表名/链名/mark 以该文件为唯一真相。

## 可行性结论

**可行，且比 sing-box `auto_redirect` 更适合网关场景。**

| 维度 | 旧方案 (auto_redirect) | 新方案 (fwmark + ip rule) |
|------|------------------------|---------------------------|
| 数据面归属 | sing-box 与内核双套路由 | **内核** 决定走向，sing-box 只处理 TUN 内流量 |
| LAN 转发 | 依赖 sing-box 自建 nft，易与 gfc nft 冲突 | **nft mangle 打标** + `ip rule`，逻辑单一 |
| 职责边界 | 模糊 | **nft 分类 / MosDNS DNS / sing-box 出站** 清晰 |
| 调试 | sing-box nft + 系统路由难拆 | `ip rule` / `ip route table 2022` / `nft list` 可观测 |

分流（Scheme B）：**内核 cn_ip 集** 判 CN 直连；非 CN 进 TUN；sing-box **不再**做 GeoSite/GeoIP 分流（`final: proxy`）。

---

## 方案 B 数据流（当前默认 `GFC_ROUTING_SCHEME=kernel-split`）

```
PC → bridge_lan
  → PREROUTING DNS → MosDNS :53
  → PREROUTING classify:
       dst ∈ cn_ip / 私网 / :53 → 无 mark → main 表 → WAN 直连
       其余 → mark 0x2023
  → ip rule → table 2022 → gfctun
  → sing-box TUN → final VLESS Reality → 转发节点

MosDNS 国际上游 (1.1.1.1/8.8.8.8:443 DoH) → uid 65353 + :443 打标 → TUN → 代理
```

| 流量 | 路径 |
|------|------|
| CN IP（china_ip_list） | **不进 TUN**，WAN 直连 |
| 非 CN IP | mark → **gfctun → VLESS** |
| MosDNS 国内 :53 上游 | 不打标，直连 |
| MosDNS 国际 DoH :443 | 打标 → TUN → 代理 |
| **转发节点 IP** | **bypass_ip**（VLESS 握手必须直连 WAN，不能进 TUN） |

验证 VLESS：`sudo bash deploy/check-vless.sh`（TCP + bypass + Clash API delay）

sing-box（scheme B）：**无 geo rule_set**，route 仅 `final: proxy`

回退标签：`kernel-split`。验证其他方案后，设置 `GFC_ROUTING_SCHEME=kernel-split` 并重新执行 `apply-network.sh` 即可回到当前默认数据面。

---

## 方案 A 数据流（已弃用默认）

```
PC
 ↓
bridge_lan
 ↓
nft PREROUTING (DNS → MosDNS :53)
nft PREROUTING mangle (TCP/UDP ≠53/67/68 → mark 0x2023)
 ↓
ip rule: fwmark 0x2023 lookup table 2022
 ↓
ip route table 2022: default dev gfctun
 ↓
sing-box TUN inbound（无 auto_route / auto_redirect）
 ↓
route rules: CN → direct (bind WAN) / 非 CN → VLESS Reality
 ↓
Relay node
```

本机发出的流量（非 sing-box / 非 :53）走 **output mangle** 同样打标，盒子本机与 LAN PC 路径一致。

---

## 方案 C 数据流（BYST 复刻验证）

启用：`GFC_ROUTING_SCHEME=byst-redirect`

```
LAN TCP 非 CN / ext / ext_const
  → nft prerouting nat redirect :11800
  → sing-box redirect inbound tcp-in
  → VLESS Reality

LAN 非 TCP 非 CN / ext / ext_const
  → nft prerouting mangle mark
  → ip rule table 2022
  → gfctun
  → sing-box TUN inbound
  → VLESS Reality
```

该方案用于复刻成熟设备的 `redirect :11800 + TUN` 双 inbound 模式。WAN 由 `GFC_WAN_IFACE` 或运行时网络角色解析，默认 TUN 设备仍为 `gfctun`。

关键差异：

- TCP 不再走 `fwmark -> gfctun`，而是 redirect 到 sing-box `11800`。
- UDP / ICMP 等非 TCP 仍走 `fwmark -> table 2022 -> gfctun`。
- `ext` 是 nft timeout set，预留给后续动态 DNS/IP 注入。
- `ext_const` 默认包含 `8.8.4.4,8.8.8.8,1.1.1.1,1.0.0.1`，可通过 `GFC_EXT_CONST_IPS` 覆盖。
- `kernel-split` 保留为回退标签，不删除。

**OUTPUT 分类顺序**（数字越小越先执行；nat hook 不可用 `-200`，该槽位留给 conntrack）：

1. DNS hijack（nat `-100` / `dstnat`）：本机/LAN :53 重定向到 MosDNS
2. mangle（route `200`，晚于 DNS）：
   - 已打标 / TUN 环回 / 私网 / :53/:67/:68 → 跳过
   - VLESS 节点 + 控制面 IP → 跳过（gfc-agent 直连）
   - `meta skuid 65354`（sing-box）→ 跳过（防 TUN 回环）
   - `meta skuid 65353` + tcp/443（MosDNS DoH）→ 打标
   - 其余 → 打标 `0x2023`

---

## 组件职责

### nftables

| 表 | 职责 |
|----|------|
| `gfc_dns_hijack` | LAN/本机 DNS 劫持 → MosDNS :53（nat `dstnat` / output `-100`） |
| `gfc_client_mangle` | LAN 转发 + 本机流量打 `fwmark 0x2023`（prerouting/output `200`，晚于 DNS/filter） |
| `gfc_client_filter` | INPUT/FORWARD（含 `lan↔gfctun`，priority `-200`） |
| `gfc_client_nat` | WAN MASQUERADE（直连兜底） |

**禁止** sing-box `auto_redirect` 自建 nft（`singbox-nft-cleanup.sh` 清理残留）。

### Linux routing

```bash
ip rule add pref 100 fwmark 0x2023 table 2022
ip route add default dev gfctun table 2022
```

常量（`deploy/lib-policy-routing.sh`）：

- `GFC_POLICY_MARK=0x2023`
- `GFC_POLICY_TABLE=2022`
- `GFC_TUN_INTERFACE=gfctun`

### sing-box

**仅负责：**

- TUN inbound（`auto_route: false`）
- VLESS + Reality outbound
- GeoIP/GeoSite 分流
- `direct` 出站 `bind_interface: <WAN>`

**禁止：** auto_route、auto_redirect、DNS、NAT、策略路由。

### MosDNS

- 独占 `:53`
- 国内 UDP 上游直连；国际 DoH:443 由打标后进 TUN

---

## systemd 启动顺序

```
network-online
 → gfc-network (nft filter/dns/policy + netplan)
 → dnsmasq (DHCP only)
 → gfc-mosdns
 → gfc-sing-box (创建 gfctun)
 → gfc-routing (ip rule + table 2022)
 → gfc-agent
 → gfc-web
```

---

## 部署模式

| 模式 | 策略路由 | mangle 打标 |
|------|----------|-------------|
| `gateway` | ✅ | ✅ |
| `transparent` | ✅ | ✅ |
| `bypass` | ❌ | ❌ |

---

## 关键文件

| 路径 | 说明 |
|------|------|
| `deploy/lib-policy-routing.sh` | mark/table 常量、nft 策略、ip rule |
| `deploy/lib-singbox-user.sh` | sing-box 固定 uid 65354 |
| `deploy/gfc-routing.sh` | 刷新 policy nft + 应用策略路由 |
| `deploy/lib-mosdns-nft.sh` | DNS 劫持 |
| `/etc/gfc-client/nftables-policy.conf` | mangle 规则 |
| `internal/render/singbox/singbox.go` | TUN 无 auto_route |

---

## 测试机升级（方案 A）

```bash
cd /opt/sip-proxy/gfc-client   # 或 rsync/scp 同步本仓库
sudo bash deploy/build.sh
sudo bash deploy/install-gfc-units.sh
sudo bash deploy/apply-network.sh
sudo bash deploy/reapply-active.sh   # 已激活线路
# 或 idle: sudo gfc-bootstrap
sudo bash deploy/verify-install.sh
sudo bash deploy/check-egress.sh
```

确认：`id singbox` → 65354；`ps -o user= -C sing-box` → singbox；无 redirect :11800。

---

## 测试机紧急修复（当前故障）

```bash
cd /opt/sip-proxy/gfc-client
git pull   # 或 scp 同步后

# 1. 停 sing-box，清 auto_route 污染
sudo systemctl stop gfc-sing-box gfc-routing 2>/dev/null || true
sudo bash deploy/singbox-nft-cleanup.sh
sudo ip -4 rule del table 2022 2>/dev/null || true
sudo ip -4 route flush table 2022

# 2. 重装 unit + 重渲染配置
sudo bash deploy/install-gfc-units.sh
sudo bash deploy/build.sh
sudo bash deploy/apply-network.sh
sudo gfc-bootstrap || sudo bash deploy/repair-dataplane.sh

# 3. 验证
sudo bash deploy/verify-install.sh
sudo bash deploy/check-egress.sh
dig @127.0.0.1 baidu.com +short
```

**根因**：旧 `sing-box.json` 仍含 `auto_route/auto_redirect`，与 table 2022 冲突；OUTPUT mangle 曾把 sing-box 自身流量打标回环导致 CPU 打满。**修复**：sing-box 以固定 uid `65354` 运行，nft `meta skuid 65354 return` 豁免打标。

---

## 测试机升级（未 push 前本地）

```bash
cd /opt/sip-proxy/gfc-client
# git pull  # 待 push 后
sudo bash deploy/build.sh
sudo bash deploy/apply-network.sh
sudo bash deploy/repair-dataplane.sh
sudo bash deploy/verify-install.sh
sudo bash deploy/check-egress.sh
```

LAN PC：网关/DNS 指向盒子，访问国内外站点。

---

## 已知注意点

1. **gfctun 必须先于 gfc-routing 启动**（已由 `ExecStartPost` / unit 顺序保证）。
2. **rp_filter** 设为 loose (`2`)，避免 TUN 非对称路径丢包。
3. **DHCP/DNS 不打标**（dport 53/67/68 排除）。
4. 国内直连仍走 sing-box `direct` + `bind_interface WAN`，不依赖 MASQUERADE。
