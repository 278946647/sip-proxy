## Data plane (transparent to SOCKS) – scaffold

Target (Linux forward node):
- Use **nftables/iptables + TPROXY** to redirect selected traffic to a local transparent proxy port.
- The proxy process selects an egress SOCKS based on **source IP** (CIDR match) and forwards via SOCKS.

### SOCKS 代理格式

控制面存储为结构化字段；UI 支持参考格式一键录入：

`username:password@IP:Port`

渲染到 sing-box 时为标准 SOCKS5（`server` / `server_port` / `username` / `password`）。

### 回程流量（VyOS → 转发节点 → SOCKS → 回程）

| 区段 | 行为 |
|------|------|
| VyOS → 转发节点 | 骨干将客户源网段流量送到转发节点（静态路由 / OpenVPN 隧道） |
| 转发节点 → SOCKS | TPROXY 按源 IP 匹配线路，sing-box 建立到上游 SOCKS 的连接 |
| SOCKS → 互联网 | 由 SOCKS 供应商侧 NAT，**回程到公网**走供应商，无需在 VyOS 写回程 |
| 互联网 → 客户 | 应答回到转发节点后，需把包送回 **客户源 IP（在 VyOS 后）** |

**同一条透明代理会话**的内核连接跟踪 + TPROXY 策略路由（`fwmark 0x1`）可处理「进 TPROXY 的流」的关联回程，但转发节点仍须有到 **客户 CIDR** 的路由，否则应答可能从默认网关走错。

因此在控制平台 **转发节点 → 回程路由** 配置静态路由（下发到 `payload.staticRoutes`，Agent 执行 `ip route replace`），例如：

- `10.0.0.0/24 via 192.168.10.1 dev eth1`（以太网直通，下一跳为 VyOS 内网口）
- `10.0.0.0/24 dev tun0`（OpenVPN，走隧道回 VyOS）

VyOS 侧仍需将客户网段指向转发节点（与线路 `source_cidrs` 一致）。

### IPv4 转发

转发节点必须 `net.ipv4.ip_forward=1`。安装脚本与 Agent 每次启动/应用配置时会写入 `/etc/sysctl.d/99-gfc-forward.conf` 并立即生效；同时自动加载 `tcp_bbr` 模块并设置 `net.ipv4.tcp_congestion_control=bbr`、`net.core.default_qdisc=fq`（内核不支持时跳过 BBR，不影响转发）。

### 客户端 REALITY 入站（VLESS + Vision）

控制面在 `payload.clientIngress` 下发：

- `reality`：节点级 REALITY 密钥、SNI、`dest`、监听端口（默认 443）
- `users[]`：每客户端线路独立 UUID；`outbound.mode` 为 `socks` 或 `direct`

转发节点 Agent 渲染 sing-box：

- **Inbound**：`vless` + REALITY（`:443`）
- **Route**：按 VLESS `user`（`client-<lineId>`）分流到对应 SOCKS 或 `direct` 出站

与 TPROXY 透明转发 **共存**于同一 `sing-box.json`：VyOS 侧走 TPROXY，客户端盒子走 REALITY 入站。

### 是否需要 NAT？

**通常不需要**在转发节点对客户流量做 SNAT/MASQUERADE：

| 场景 | 是否需要 NAT |
|------|----------------|
| VyOS → 转发节点（TPROXY 入向） | 否，保持客户源 IP 供 sing-box 按 CIDR 选 SOCKS |
| 转发节点 → 上游 SOCKS | 否，sing-box 以 SOCKS 协议代发，源地址由 SOCKS 会话处理 |
| 应答 → 客户私网（经 VyOS 回程） | 否 SNAT；需 **静态路由** 指回 VyOS，不用把内网 NAT 成 SOCKS 公网 IP |

仅在特殊拓扑（例如必须把出网口源 IP 伪装成某固定公网）时才考虑额外 nftables SNAT，本 MVP 架构不默认开启。

### MVP choice

- **TPROXY + sing-box** (recommended):
  - sing-box transparent inbound + per-source-CIDR outbound SOCKS.
  - NodeAgent renders `sing-box.json`, `gfc.nft`, and applies `staticRoutes`.
- Alternative: `redsocks2` + iptables + custom dispatcher.

This repo provides install scaffolding on forward nodes; configure `GFC_TPROXY_IFACE` and static routes in the Web UI.

