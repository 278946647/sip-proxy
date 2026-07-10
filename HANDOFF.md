# GFC 会话交接（HANDOFF）

> 写给**完全没有上下文**的新对话。  
> 最后更新：**2026-07-10**（ImmortalWrt 客户端稳定性 + 远程运维 + 数据面 LAN 验收）。  
> 仓库：`sip-proxy`（`gfc-platform/` 控制平台 + `gfc-client/` ImmortalWrt 客户端）。

**说明：** `main` 在本交接写入之后可能还有**其他并行工作**（如全局路由/代理模式拆分 `731fee3` 起）。若任务涉及「设备设置页路由模式」，请先 `git log` 看 `ceecc16` 一带提交，并与本文 **§2 范围** 区分。

---

## 1. 本会话在做什么（任务总览）

| 主题 | 目标 |
|------|------|
| **远程 SSH / Web 运维** | 控制平台对 NAT 后 ImmortalWrt 按需反向隧道 + WebSSH + LuCI 反代；P2 加固 |
| **apply-network 事故修复** | `gfc-bootstrap --apply-network` 误改 WAN 导致丢 IP；快照/回滚/seed |
| **PPPoE WAN** | 与 static/dhcp 对齐的 UCI 字段清理 + 单测 |
| **安装/升级后下联 PC 不能上网** | unbound bootstrap、NAT/DNS hijack、fw4 冲突 |
| **流程固化** | 底层改动必须先差异表 + 用户确认；验收脚本 |

**产品 tag（远程运维里程碑）：** `gfc-remote-ssh-web-v1.0.0`

---

## 2. 已经完成了什么

### 2.1 控制平台 — 远程运维（`gfc-platform/`）

| 项 | 状态 | 说明 / 提交 |
|----|------|-------------|
| P2-3 危险操作确认 | ✅ | `dangerousConfirm.ts`；删设备需 `confirm=true` |
| P2-4 网络变更后隧道恢复 | ✅ | `restore.go`；`/var/run/gfc-restore-reverse-ssh` |
| P2-5 文档 | ✅ | `REMOTE_ACCESS.md`、`OPS.md`、`ARCHITECTURE.md` |
| P2-6 端口删除冷却 | ✅ | `released_reverse_ports`；默认 3600s |
| WebSSH 终端乱码 | ✅ | xterm.js；`TERM=xterm-256color`（`454a873`） |
| LuCI 反代 405/401 等 | ✅ | `0e13115` 前后一系列 `remote_proxy.py` 修复 |

**部署边界：** 远程 SSH/Web/危险确认/端口冷却 → **仅控制面 API + web-ui**；设备可不升 `gfc-client`（除隧道恢复、apply-network 相关）。

### 2.2 客户端 — WAN apply（`gfc-client/internal/network/`）

| 项 | 状态 | 提交 |
|----|------|------|
| WAN 安全 apply（seed UCI、写前快照） | ✅ | `454a873` |
| `gfc-bootstrap --rollback-network` | ✅ | `openwrt_snapshot.go` |
| 默认不碰 LAN（`GFC_MANAGE_LAN`） | ✅ | `network.go` |
| PPPoE `username/password` + 清 static 残留 | ✅ | `openwrt_wan.go` + 单测（`adf9125`） |
| 规范文档 | ✅ | `gfc-client/docs/NETWORK_APPLY.md` + `.cursor/rules/network-apply-no-change-without-approval.mdc`（`f1d7453`） |

### 2.3 客户端 — 安装/升级/数据面 LAN

| 项 | 状态 | 提交 |
|----|------|------|
| unbound `root.key` / chroot checkconf 失败 | ✅ | 不再 patch 到 `/etc/unbound/root.key`；`chroot: ""`；`EnsureTrustAnchorLayout`（`4325b3d`） |
| unbound snippet include 缺失导致 bootstrap 失败 | ✅ | `share/unbound/local.d/*`、`conf.d/gfc-domestic-forward.conf`；`EnsureTree` 复制（`9416ce9`） |
| 无 `sing-box.json` 时不启 `gfc-routing` → 无 NAT | ✅ | install/upgrade **始终先启 gfc-routing**（`9416ce9`） |
| 下联验收脚本 | ✅ | `deploy/immortalwrt/verify-dataplane-dns.sh` |
| 底层变更协议 | ✅ | `gfc-client/docs/DATAPLANE_CHANGE.md` + `.cursor/rules/dataplane-bottom-layer.mdc` |
| **ImmortalWrt fw4 与 GFC nft 冲突** | ✅ | `disable-immortalwrt-fw4.sh`；apply-network **不再 restart firewall**（`3f5a379`、`302bd64`） |

### 2.4 反向 SSH — 设计澄清（本会话确认，非新代码）

| 项 | 结论 |
|----|------|
| `/etc/init.d/gfc-reverse-ssh` **disabled + stopped** | **正常**；仅管理员在 UI 建远程会话后由 agent `enable` + 拉起 autossh |
| 端口池 | 设备长期绑定 `reverse_ssh_port` / `reverse_http_port`；测「冷启动耗时」**不必删端口**，应 `DELETE .../reverse-ssh/session` + 设备停 autossh |

---

## 3. 当前卡在哪 / 未闭环项

| 项 | 状态 | 说明 |
|----|------|------|
| **设备 runtime 版本** | ⚠️ 待确认 | 现场需安装含 **`302bd64` 或更新** 的 `gfc-immortalwrt-runtime-*`；仅改控制面不能修 LAN/fw4/unbound |
| **下联 PC 上网** | ⚠️ 待验收 | 代码已修；用户曾手动关 fw4 后恢复；应用新包后应跑 `verify-dataplane-dns.sh` |
| **远程 SSH 冷启动耗时** | ⚠️ 未记录 | 预期约 **6–15s**（心跳 2–3s + autossh + UI 800ms 轮询）；未留下实测数字 |
| **Windows 开发机** | ℹ️ | 无 `go` 命令，单元测试需在 Linux/设备上跑 |
| **main 后续提交** | ℹ️ | `302bd64` 之后有路由/代理模式拆分、RBAC、流量配额等（见 `git log 302bd64..HEAD`），与本文 LAN/fw4 线可并行但别混谈 |

### 参考环境（会话中出现过）

- 控制面：`103.78.41.16:5173`（Web），API `8080`
- 设备 WAN：曾 static `103.78.41.17/27`，`GFC_WAN_IFACE=eth0`
- LAN：dnsmasq `port=0`，DHCP option 6 指向网关（如 `192.168.1.1`）

---

## 4. 下一步计划（建议顺序）

### P0 — 设备对齐最新 runtime + LAN 验收

```sh
# 设备上（新 runtime 包或 git pull 后 install）
./install.sh

# 或手动：
sh /usr/lib/gfc-client/deploy/immortalwrt/ensure-unbound-dirs.sh
GFC_PLATFORM=immortalwrt gfc-bootstrap
sh /usr/lib/gfc-client/deploy/immortalwrt/disable-immortalwrt-fw4.sh
/etc/init.d/gfc-unbound restart
/etc/init.d/gfc-routing start
sh /usr/lib/gfc-client/deploy/immortalwrt/configure-dnsmasq-dhcp.sh
/etc/init.d/dnsmasq restart
sh /usr/lib/gfc-client/deploy/immortalwrt/verify-dataplane-dns.sh
```

下联 PC：`ipconfig /renew` 或重连 Wi‑Fi。

### P1 — 远程 SSH 冷启动复测

1. `DELETE /admin/client-devices/{id}/reverse-ssh/session`
2. 设备：`/etc/init.d/gfc-reverse-ssh stop`；确认 `pidof autossh` 为空
3. UI 点「远程 SSH」，记「确认 → tunnel_ready」秒数
4. **不要删设备**测端口（除非测端口池/冷却）

### P2 — 控制面（若尚未部署）

- API + web-ui 含 `0e13115`（P2）、`454a873`（xterm）
- 见 `gfc-platform/docs/REMOTE_ACCESS.md`

### P3 — 以后改底层代码

1. 读 `DATAPLANE_CHANGE.md` + 对应 `*_ARCHITECTURE.md`
2. 输出 **规范 vs 实现差异表**
3. 用户回复 **「确认修改」** 后再写代码
4. 改后设备跑 **`verify-dataplane-dns.sh`**

---

## 5. 踩过的坑 — 新对话不要再踩

### 5.1 WAN / apply-network

| 坑 | 正确做法 |
|----|----------|
| 无 `network-wan.json` 时默认写 `proto=dhcp` | **先从 UCI seed**；无 JSON 则跳过 WAN 或报错（`GFC_MANAGE_WAN`） |
| LuCI「回滚配置」能恢复 WAN | **不能**；仅数据面。系统网络用 `gfc-bootstrap --rollback-network` |
| PPPoE/static 切换不删 UCI 残留 | 必须走 `buildWANApplyPlan()` 清理矩阵 |
| `apply-network` **restart firewall** | 会拉起 **fw4**，与 GFC nft 冲突 → 已改为 **stop+disable** |

### 5.2 DNS / unbound / 下联 PC

| 坑 | 正确做法 |
|----|----------|
| patch `auto-trust-anchor` 到 `/etc/unbound/root.key` | ImmortalWrt checkconf 按 chroot 校验 → **fatal**；保持 `/var/lib/unbound/root.key` + `chroot: ""` |
| template include 的 3 个 snippet 未部署 | bootstrap 失败 → **:53 无服务** → 全网打不开 |
| dnsmasq `port=0` 且无 DHCP option 6 | 下联 PC **无 DNS** |
| 仅当存在 `sing-box.json` 才启 `gfc-routing` | bootstrap 失败时 **无 masquerade** → 能解析也不能上网 |

### 5.3 nft / fw4

| 坑 | 正确做法 |
|----|----------|
| ImmortalWrt **fw4 默认开启** | 与 `inet gfc` / `inet nat` / `gfc_dns_hijack` **冲突**；必须 `disable-immortalwrt-fw4.sh` |
| 以为 GFC 用 UCI firewall masq | NAT 由 **`gfc-routing.sh` `apply_wan_nat`** 负责 |

### 5.4 远程 SSH

| 坑 | 正确做法 |
|----|----------|
| `gfc-reverse-ssh` disabled | **正常**；无会话不建隧道 |
| 删设备才能「清端口」测冷启动 | 只需 **结束 session** + 停 autossh；删设备会进 **3600s 冷却** |
| 数据面回滚 vs 网络回滚 | 见 `NETWORK_APPLY.md` §2 |

### 5.5 开发与流程

| 坑 | 正确做法 |
|----|----------|
| 未读架构文档就改 unbound/nft/sing-box/network | 违反 `.cursor/rules/*-no-change-without-approval.mdc` |
| bootstrap 失败仍 `|| true` 不验收 | install 末尾应看 **`verify-dataplane-dns.sh`** 输出 |
| 在 Windows 上跑 `go test` | 环境可能无 Go；用设备或 CI |

---

## 6. 权威文档与 Cursor 规则（改代码前必读）

| 领域 | 权威 `.md` | AI 变更协议 `.mdc` |
|------|------------|---------------------|
| nft | `docs/NFT_ARCHITECTURE.md` | `nft-no-change-without-approval.mdc` |
| DNS/unbound | `docs/UNBOUND_ARCHITECTURE.md` | `unbound-no-change-without-approval.mdc` |
| sing-box | `docs/SINGBOX_ARCHITECTURE.md` | `singbox-no-change-without-approval.mdc` |
| WAN apply | `gfc-client/docs/NETWORK_APPLY.md` | `network-apply-no-change-without-approval.mdc` |
| 数据面总览/验收 | `gfc-client/docs/DATAPLANE_CHANGE.md` | `dataplane-bottom-layer.mdc` |
| 远程运维 | `gfc-platform/docs/REMOTE_ACCESS.md` | — |

**固定口令（建议用户附带）：**

> 严格按 `DATAPLANE_CHANGE.md` / `NETWORK_APPLY.md` / `*_ARCHITECTURE.md`，只改我点名的文件，改前先给差异表，确认后再写代码；改后跑 `verify-dataplane-dns.sh`。

---

## 7. 关键 Git 提交（本会话数据面 + 远程运维，由旧到新）

```
0e13115  feat(p2): remote ops hardening (#3–#6)
454a873  fix: safe apply-network WAN + xterm WebSSH
adf9125  fix(client): OpenWrt PPPoE WAN apply
f1d7453  docs: NETWORK_APPLY + Cursor protocol
4325b3d  fix(client): unbound root.key ImmortalWrt bootstrap
9416ce9  fix(client): LAN DNS/NAT after upgrade gaps + verify script
3f5a379  fix(client): disable ImmortalWrt fw4
302bd64  docs: network rollback disables fw4
```

远程运维更早基底：`gfc-remote-ssh-web-v1.0.0` tag；细节见 `gfc-platform/docs/REMOTE_ACCESS.md`。

---

## 8. 关键文件索引

```
gfc-client/
  cmd/gfc-bootstrap/main.go          # --apply-network, --rollback-network
  internal/network/
    openwrt_wan.go                     # buildWANApplyPlan (static/dhcp/pppoe)
    openwrt_snapshot.go                # network 快照/回滚
    openwrt_fw4.go                     # disableOpenWrtFW4
  internal/render/unbound/unbound.go   # EnsureTree, trust anchor, OpenWrt patch
  internal/reversessh/                 # autossh, 网络后 restore
  deploy/immortalwrt/
    install-runtime.sh / upgrade-runtime.sh
    ensure-unbound-dirs.sh
    disable-immortalwrt-fw4.sh         # ★ fw4 必须关
    verify-dataplane-dns.sh            # ★ 下联验收
    gfc-routing.sh                     # NAT + DNS hijack + gfc nft
    configure-dnsmasq-dhcp.sh
  docs/NETWORK_APPLY.md
  docs/DATAPLANE_CHANGE.md

gfc-platform/
  control-plane/api/app/reverse_ssh.py, webssh.py, remote_proxy.py, admin.py
  web-ui/src/lib/reverseSsh.ts, openRemote.ts, utils/dangerousConfirm.ts
  docs/REMOTE_ACCESS.md
```

---

## 9. LAN 数据路径（验收心智模型）

```
下联 PC
  → DHCP option 6 = 网关 LAN IP
  → DNS → 网关:53 → gfc-unbound
  → nft gfc_dns_hijack（外连 DNS 重定向 :53）
  → nft nat masquerade（gfc-routing，且 fw4 必须 disabled）
  → 国内 TO_CN 直连 WAN / 国际 mark → gfctun → sing-box（已激活时）
```

**任一环断 → 下联打不开网页或仅部分站点失败。**

---

## 10. 给新对话的一句开场白

> 我们在 ImmortalWrt 上修 **install/apply-network 后下联 PC 不能上网**：unbound bootstrap、gfc-routing 与 sing-box 解耦、**禁用 fw4**、验收脚本已进 `main`（至 `302bd64`）。请帮用户在设备上 **install 最新 runtime** 并跑 `verify-dataplane-dns.sh`；若仍失败贴脚本输出。改底层前先读 `DATAPLANE_CHANGE.md` 出差异表。远程 SSH 按需建连，`gfc-reverse-ssh` 平时 disabled 正常。勿在未批准时改 `NFT/UNBOUND/SINGBOX_ARCHITECTURE.md` 契约。

---

*若本文与 `docs/NFT_ARCHITECTURE.md`、`docs/UNBOUND_ARCHITECTURE.md`、`docs/SINGBOX_ARCHITECTURE.md` 冲突，以权威架构文档为准。*
