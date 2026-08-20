# GFC 架构与业务场景测试计划

> **版本：** 对齐当前交付（控制平台 + 网关模式 `kernel-split`）  
> **权威数据面规范：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) · [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) · [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)  
> **用途：** 功能模块验收、分流正确性、业务上网场景与 VPN/骨干能力是否满足

---

## 1. 测试范围与原则

### 1.1 产品定位（测试口径）

GFC 是**企业级跨境边缘网关 + 管控平台**，不是消费级「VPN App」。

| 应测能力 | 不应按消费级 VPN 验收 |
|----------|----------------------|
| LAN 终端透明上网、中外分流 | 客户端 App、一键拨号 UI |
| 线路码激活、按线路 SOCKS 出境 | Fake-IP 作为主 DNS 方案 |
| VLESS Reality 加密隧道 | WireGuard / Hysteria / TUIC（未验证） |
| OpenVPN 站点到站点骨干（可选） | 终端自建 OpenVPN 客户端替代网关 |

### 1.2 三层架构（必须全覆盖）

```
控制平台 (Web :5173 / API :8080)
        │ 配置下发 / 心跳
        ├──────────────┬──────────────┐
        ▼              ▼              ▼
   转发节点 VM      转发节点 …     客户端网关
   TPROXY/VLESS                    ImmortalWrt /
   → SOCKS 出境                    Ubuntu 软路由
```

**控制面与数据面分离验收：** 平台宕机后，已下发的 sing-box / nft / 路由仍应转发；仅失去集中管理与配置推送。

### 1.3 判定标准

| 符号 | 含义 |
|------|------|
| ✅ 满足 | 当前架构与实现可验收通过 |
| ⚠️ 有条件满足 | 依赖正确配置/上游 SOCKS/骨干，或仅部分路径验证 |
| ❌ 不满足 / 未交付 | 明确非目标或未验证，不得当作已交付能力 |

---

## 2. 测试环境矩阵

| 角色 | 推荐环境 | 关键端口 | 冒烟脚本 |
|------|----------|----------|----------|
| 控制平台 | Ubuntu 20.04+，Docker | UI `5173`，API `8080`（部分 OPS 文档写 `8181`，以实际 compose 为准） | `curl -fsS http://<CP>/healthz` |
| 转发节点 | Ubuntu 裸机 | VLESS `8443`，TPROXY `12345`，SSH `212`，OpenVPN `1194`（可选） | `sudo bash deploy/node/verify-node.sh` |
| 客户端网关 | ImmortalWrt（主）/ Ubuntu 22.04 | unbound `53`，gfc-api `8080`，Clash API `9090`，激活页 `80` | ImmortalWrt：`verify-dataplane-dns.sh`；VLESS：`check-vless.sh` |

**环境变量注意：** WAN/LAN/TPROXY/SNAT 网卡运行时发现，测试用例禁止写死 `eth0` / `192.168.1.0/24`。

---

## 3. 功能模块测试清单

### 3.1 控制平台（`gfc-platform/control-plane`）

| ID | 模块 | 测试要点 | 期望 |
|----|------|----------|------|
| CP-01 | 安装与健康 | Docker 一键安装；`/healthz`；UI 登录；强制改密 | 全部成功 |
| CP-02 | 节点管理 | Bootstrap Token 激活节点；仪表盘在线；心跳约 10s | 节点 Online |
| CP-03 | 线路 / SOCKS | 创建线路、绑定 SOCKS、启用/禁用、带宽 Mbps | 节点 bundle 反映变更 |
| CP-04 | SOCKS 探测 | 控制面探测上游 SOCKS 可达 | 健康状态正确 |
| CP-05 | 客户端设备 | 线路码激活设备；设备上线；配置 ACK | 设备与线路绑定正确 |
| CP-06 | Reality 契约 | 节点入站与客户端出站：端口、SNI、密钥一致 | 默认 `8443` / `www.cloudflare.com` |
| CP-07 | 远程运维 | Reverse SSH / WebSSH / LuCI 代理（`212`/`80`） | 可登录设备 |
| CP-08 | 权限 / 用户 | RBAC、多用户、操作日志 | 越权失败 |
| CP-09 | 告警 | 邮件 / 飞书（若已配置） | 节点离线等可告警 |
| CP-10 | 平台宕机 | 停 API/UI 后已有流量 | 数据面仍通；仅管理失效 |

**单元测试（开发回归）：** `control-plane/api/tests/`（`test_client_config`、`test_line_code`、`test_reality_util`、`test_permissions`、`test_remote_proxy` 等）。

---

### 3.2 转发节点（`gfc-platform/node-agent`）

| ID | 模块 | 测试要点 | 期望 |
|----|------|----------|------|
| ND-01 | Agent 安装 | `install.sh` → `verify-node.sh` | agent / sing-box active |
| ND-02 | client-ingress | VLESS `:8443`；用户名 `client-{lineId}`；路由字段 **`auth_user`**（禁止 `user`） | 按线路进对应 SOCKS |
| ND-03 | 线路隔离 | 线路 A 用户不得落到线路 B 的 SOCKS | 未知用户走 `route.final: direct` |
| ND-04 | TPROXY 路径 | 入向网卡 → nft → `:12345`；源 CIDR → SOCKS | 与静态回程路由一致 |
| ND-05 | bypass | `@bypass_ip` 不进 TPROXY | 控制面/自身可达 |
| ND-06 | 策略路由 | mark `0x1` → table 1 → WAN；mark `0x100` → table 100 → lo | 回程正常 |
| ND-07 | SNAT | `ip gfc-nat`；`default_interface` 运行时发现 | 出境 SNAT 正确 |
| ND-08 | OpenVPN 骨干 | `connect_mode=openvpn`；`openvpn@gfc-backbone`；TPROXY 可切 `tun0` | 隧道 up 且流量可走 |
| ND-09 | SOCKS 健康 | `test-socks.sh` / agent 探测 | 坏 SOCKS 可观测 |

**单元测试：** `node-agent/tests/test_singbox_client_ingress.py`、`test_nft_render.py`。

---

### 3.3 客户端网关（`gfc-client`）

| ID | 模块 | 测试要点 | 期望 |
|----|------|----------|------|
| CL-01 | 安装 / idle | bootstrap：NAT + DNS 劫持；激活前可本地管理 | ImmortalWrt 关 stock fw4 |
| CL-02 | 激活 | 线路码 / 激活页 `:80/gfc/activate.html` | 拉配置并 ACK |
| CL-03 | DNS unbound | 仅 unbound 听 `:53`；dnsmasq `port=0`；DHCP option `6,<LAN>` | 与 UNBOUND 规范一致 |
| CL-04 | DNS 分流 | 国内域名（如淘宝）→ 国内上游；国际（如 google）→ DoT 国际上游 | 解析成功且路径符合规范 |
| CL-05 | DNS 劫持 | LAN 直连 `8.8.8.8:53` 被劫持到本机 unbound | 不可绕过 |
| CL-06 | nft 表链 | 存在 `inet nat` / `gfc_dns_hijack` / `gfc`；链名与 hook 优先级符合规范 | 不得改名 |
| CL-07 | 分流 split | `TO_CN` → WAN；非 CN → mark `0x2023` → table `2022` → `gfctun` | 见第 4 节 |
| CL-08 | bypass | 节点 IP、控制面、Reality 目标在 `bypass_ip` | VLESS 握手不进 TUN |
| CL-09 | 私网 / SSH | RFC1918、LAN、`:53/:67/:68/:123`、SSH `212` 不进代理 | 管理与内网正常 |
| CL-10 | sing-box | `gfctun`、`auto_route:false`、无 geo `rule_set`、`proxy-prefer` 仅含 proxy、`final:direct` | `sing-box check` 通过 |
| CL-11 | VLESS | `check-vless.sh`：TCP + bypass + Clash delay | 延迟可测、链路通 |
| CL-12 | 代理模式 | `gateway`（默认）/ `bypass` / `transparent` | 模式切换符合契约 |
| CL-13 | 路由方案 | 生产默认 `kernel-split`；`global` 与 `split` 差异见第 4 节 | 不以 legacy 方案验收生产 |
| CL-14 | LuCI / gfc-api | 本地 REST `:8080`；LuCI 管理 | 可查看状态与配置 |
| CL-15 | Reverse SSH | 经控制面远程 SSH/LuCI | 运维可达 |

**单元 / 生成器测试：** `internal/render/singbox`、`unbound`、`deploy/tests/test_gen_nft_policy.py`。

> **注意：** `deploy/verify-install.sh`（Ubuntu）若仍检查 MosDNS，以 ImmortalWrt `verify-dataplane-dns.sh` + 权威 `docs/*_ARCHITECTURE.md` 为准。

---

## 4. 分流与上网路径测试（核心）

### 4.1 客户端 `split`（默认生产）

| ID | 场景 | 验证方法（示例） | 期望路径 |
|----|------|------------------|----------|
| SP-01 | 国内网站（CN IP） | 访问淘宝/百度；`tcpdump`/`conntrack` 看是否进 `gfctun` | **WAN 直连**，不进 TUN |
| SP-02 | 国际网站 | 访问 google/youtube；观察 mark / table 2022 | **mark → gfctun → VLESS → 节点** |
| SP-03 | 国内 DNS | `drill @127.0.0.1 taobao.com` | 国内上游；查询不进代理 |
| SP-04 | 国际 DNS | `drill @127.0.0.1 google.com` | DoT；上游 IP 经 `ext_const` 可走代理 |
| SP-05 | 绕过 DNS | LAN 设备向 `8.8.8.8:53` 查询 | 被劫持到 unbound |
| SP-06 | 节点可达 | ping/curl 节点 `:8443` | **bypass**，不进 TUN |
| SP-07 | 控制面可达 | 访问 CP UI/API | **bypass** |
| SP-08 | 代理宕机 | 停 sing-box；访问 CN 站 | CN 仍 WAN 通；国际失败（**不静默直连泄漏**） |
| SP-09 | WAN 伪装 | `inet nat` masquerade | 直连流量可出网 |
| SP-10 | 动态 ext | 国际目的进入 `ext`（timeout） | 后续分类仍走代理路径 |

### 4.2 客户端 `global`（全代理，除 bypass）

| ID | 场景 | 期望 |
|----|------|------|
| GL-01 | CN 公网 IP | 也进 TUN（无 `TO_CN return`） |
| GL-02 | bypass 仍生效 | 节点/CP 不进 TUN，VLESS 可握手 |

### 4.3 转发节点按线路出境

| ID | 场景 | 期望 |
|----|------|------|
| LN-01 | 线路绑定 SOCKS A | 该线路出口 IP = SOCKS A 出口 |
| LN-02 | 线路绑定 direct | 出口 = 节点 WAN |
| LN-03 | 两台客户端不同线路 | 出口互相隔离 |
| LN-04 | 未知 VLESS 用户 | `final: direct`，**不得**落到他人 SOCKS |

### 4.4 结构验收命令（客户端）

```sh
nft list tables                    # nat, gfc_dns_hijack, gfc
ip rule list | grep 0x2023
ip route show table 2022           # default dev gfctun
ss -ulnp | grep ':53 '             # unbound only
uci get dhcp.@dnsmasq[0].port      # 0
unbound-checkconf /etc/unbound/unbound.conf
sing-box check -c /etc/gfc-client/sing-box.json
curl -s http://127.0.0.1:9090/proxies/proxy-prefer
sh /usr/share/gfc-client/deploy/check-vless.sh   # 或 deploy/check-vless.sh
```

### 4.5 结构验收命令（转发节点）

```sh
nft list table inet gfc
nft list table ip gfc-nat
ip rule list
ip route show table 100
ip route show table 1
sing-box check -c /etc/gfc-node/sing-box.json
ss -ulnp | grep 12345
systemctl is-active gfc-node-agent gfc-sing-box
sudo bash deploy/node/verify-node.sh
```

---

## 5. 业务场景是否满足（验收矩阵）

说明：**「满足」指产品架构可支撑该业务上网形态**；实际效果仍依赖上游 SOCKS 质量、带宽配额、对端线路与本地运营商质量。

| 业务场景 | 典型需求 | GFC 对应能力 | 判定 | 测试关注点 |
|----------|----------|--------------|------|------------|
| **跨境办公 / SaaS** | 访问境外办公套件、邮件、文档；国内站直连 | split 分流 + VLESS | ✅ | SP-01/02；办公域名解析与登录会话稳定 |
| **跨境电商运营** | 店铺后台、广告、收款平台走海外出口；国内支付/物流直连 | 按线路 SOCKS + CN 直连 | ✅ | 线路出口 IP 固定/正确；后台登录风控；长连接不断 |
| **ERP / 国内业务系统** | 仅国内、低延迟 | `TO_CN` + bypass | ✅ | 不得误进代理；内网 RFC1918 不通代理 |
| **直播 / 实时音视频** | 低抖动、UDP、长稳 | TUN 透传 UDP + 优质 SOCKS | ⚠️ | UDP 媒体是否通；抖动/丢包；上游 SOCKS 是否支持 UDP；需压测与真实线路 |
| **AI / 境外 API** | HTTPS 出国际、稳定出口 | 国际走 VLESS→SOCKS | ✅ | TLS 握手；出口 IP；限速策略是否生效 |
| **多租户 / 多店铺隔离** | 不同店铺不同出口 | 多线路 `auth_user` + 多 SOCKS | ✅ | LN-01~04；禁止串线 |
| **总部—边缘骨干（站点 VPN）** | VyOS/机房与转发节点加密互联 | OpenVPN `gfc-backbone` + TPROXY on `tun0` | ⚠️ | ND-08；需按部署手册配 VyOS；属可选骨干，非默认必装 |
| **消费级 VPN（手机 App 拨入）** | 终端安装 VPN 客户端连回家 | 非产品形态 | ❌ | 不验收；终端应挂在网关 LAN 下透明上网 |
| **全网全局代理** | 国内外一律走隧道 | `global` 模式 | ✅ | GL-01/02；确认业务需要后再开 |
| **WireGuard / Hysteria / TUIC** | 替代 VLESS 隧道 | 架构标明待验证 | ❌ | 不得当作已交付 |
| **IPv6 业务** | 纯 IPv6 分流 | 当前数据面以 IPv4 为主 | ❌ | 需架构评审后再测 |
| **远程运维设备** | 售后 SSH/LuCI | Reverse SSH / WebSSH | ✅ | CP-07、CL-15 |
| **平台短暂故障** | 业务不停网 | 控制/数据面分离 | ✅ | CP-10 |

### 5.1 「VPN」口径澄清（测试与销售对齐）

| 说法 | 在 GFC 中的真实含义 | 是否满足 |
|------|---------------------|----------|
| 「上网像 VPN 一样加密出境」 | 客户端 ↔ 转发节点：**VLESS + Reality** | ✅ |
| 「公司机房站点到站点 VPN」 | 转发节点 ↔ VyOS：**OpenVPN 骨干**（可选） | ⚠️ 有条件 |
| 「给员工发一个 VPN 软件」 | 消费级客户端 | ❌ 非目标 |
| 「透明网关，电脑不用装客户端」 | LAN DHCP + DNS + nft 分流 | ✅ 主交付形态 |

---

## 6. 端到端（E2E）推荐用例

### E2E-A：标准网关跨境上网（必测）

1. 部署 CP → 节点 → 客户端，完成激活。  
2. LAN PC 获取 DHCP，DNS 为网关。  
3. 访问国内站：直连、延迟接近本地运营商。  
4. 访问国际站：经代理；出口 IP = 该线路 SOCKS 出口。  
5. `check-vless.sh` 通过；节点 / 客户端仪表盘在线。

**通过标准：** SP-01~07、CL-03~11、LN-01 全部通过。

### E2E-B：双线路隔离（电商多店）

1. 两线路绑定不同 SOCKS。  
2. 两台网关（或两次激活）各绑一线。  
3. 分别查公网出口 IP，必须不同且对应 SOCKS。  
4. 故意用错误 UUID/用户访问节点，不得落到另一线路 SOCKS。

**通过标准：** LN-01~04。

### E2E-C：OpenVPN 骨干 + TPROXY（可选）

1. CP 下发 OpenVPN 配置；节点 `openvpn@gfc-backbone` up。  
2. TPROXY 入向为 `tun0`（或文档约定 iface）。  
3. VyOS 侧源网段命中正确 SOCKS；回程静态路由正常。

**通过标准：** ND-04、ND-06、ND-08。

### E2E-D：故障与安全

1. 停 sing-box：国际失败，国内仍通，**无国际静默直连**。  
2. 停控制面：已有会话/已下发策略仍通。  
3. SSH `212`、管理口始终可达。

**通过标准：** SP-08、CP-10、CL-09。

---

## 7. 业务压测建议（直播 / 电商）

| 项 | 建议 |
|----|------|
| 并发 TCP | 多会话 HTTPS 拉流/刷后台，观察 CPU、conntrack、TUN 吞吐 |
| UDP | 若直播依赖 UDP，用真实推流或 `iperf3 -u` 经代理路径 |
| 长稳 | 4–24h 会话不断开、无 DNS 异常升高 |
| 切换 | 更换 SOCKS / 禁用线路后，新连接应在预期时间内切到新出口 |
| 观测 | 节点流量统计、Clash delay、SOCKS 健康、告警是否触发 |

直播场景判定为 **⚠️**：架构支持 UDP/长连接，但**能否商用取决于上游 SOCKS 与带宽**，必须用真实线路压测签字。

---

## 8. 回归自动化清单

| 层级 | 命令 / 路径 |
|------|-------------|
| 控制面 pytest | `gfc-platform/control-plane/api/tests/` |
| 节点 agent pytest | `gfc-platform/node-agent/tests/` |
| 客户端 Go test | `gfc-client/internal/.../*_test.go` |
| nft 生成器 | `gfc-client/deploy/tests/test_gen_nft_policy.py` |
| 节点冒烟 | `gfc-platform/deploy/node/verify-node.sh`、`test-socks.sh` |
| 客户端 VLESS | `gfc-client/deploy/check-vless.sh` |
| ImmortalWrt DNS | `gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh` |

发布前建议：**单元通过 + E2E-A + E2E-D**；涉及多店加 **E2E-B**；涉及 VyOS 骨干加 **E2E-C**。

---

## 9. 缺陷判定规则

1. 生成器输出与 `docs/NFT_ARCHITECTURE.md` / `UNBOUND_ARCHITECTURE.md` / `SINGBOX_ARCHITECTURE.md` 不一致 → **按 bug 修代码**，禁止改文档迁就错误实现。  
2. 国际流量在 VLESS 故障时静默走 WAN → **严重安全/合规缺陷**。  
3. 未知用户落到其他线路 SOCKS → **严重隔离缺陷**。  
4. dnsmasq 监听 `:53` 或 MosDNS 作为生产 LAN DNS → **架构违规**。  
5. 客户端 `auto_route: true` 或用 geo `rule_set` 做中外分流 → **架构违规**。

---

## 10. 测试记录模板（可复制）

| 字段 | 填写 |
|------|------|
| 日期 / 版本 / 环境 | |
| 方案 | `kernel-split` + `split` / `global` |
| 用例 ID | |
| 步骤与命令 | |
| 实际结果 | |
| 判定 | Pass / Fail / Blocked |
| 日志附件 | nft list、sing-box check、check-vless、出口 IP |

---

## 11. 结论摘要（给业务 / 售前）

| 问题 | 结论 |
|------|------|
| 能否做企业跨境上网网关？ | **能（✅）**，主路径已生产验证（`kernel-split`） |
| 能否中外分流？ | **能（✅）**，nft `TO_CN` + unbound DNS 分流 |
| 能否多店铺多出口？ | **能（✅）**，线路 + SOCKS + `auth_user` |
| 算不算 VPN？ | **加密隧道有（VLESS Reality）；站点 VPN 可选（OpenVPN）；不是消费级 VPN 软件** |
| 直播是否保证？ | **架构支持，效果依赖上游线路，需专项压测（⚠️）** |
| WireGuard / IPv6？ | **当前不作为已交付能力（❌）** |
