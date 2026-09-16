# 会话交接：透明 veth runtime 里程碑 · 下一会话做交换机多主机（2026-09-16）

> 写给**无本对话上下文**的新会话：**先读本文再推进**。  
> **产品唯一真相：** [`TRANSPARENT_MODE.md`](TRANSPARENT_MODE.md)  
> **nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) §9.4  
> **sing-box：** [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)（§8 仍写「透明一律 `br-trans`」；**与本里程碑代码不一致**，见 §2）  
> **unbound：** [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md)  
> **上一实验室闭环：** [`SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md`](SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md)（无 veth 的 MAC-punt 闭环；**veth JSON 探针已过时**）  
> **一期实现批准（表名）：** [`SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md)  
> Cursor：`.cursor/rules/transparent-mode.mdc` / `singbox-no-change-without-approval.mdc` / `nft-no-change-without-approval.mdc` / `unbound-no-change-without-approval.mdc` / `gfc-version-release.mdc`  
> 版本：[`VERSION_AND_RELEASE.md`](VERSION_AND_RELEASE.md) §1.5 — **试编 / 本里程碑不升产品号**

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 实验室（新 OEM + 本 runtime） | **单上联 + 单路由型 CE（VyOS）可用**：国内 DNS、国际 DoT/VLESS、CPE `nslookup`/Web 已通过 |
| PE 学错 | **已堵住**：isp 上后到的假网关 ARP 不再覆盖先学到的 PE MAC |
| 产品 `vX.Y.Z` / `PKG_RELEASE` | **未升**（§1.5）。本批是研发 annotated tag，**不是发版** |
| Git | `milestone/transparent-veth-runtime-20260916`（本交接所在提交） |
| 量产基线 | **还不是**。缺正式 runtime 分发、规格文档与代码对齐、交换机多主机 SKU、切换回滚全量验收 |
| 下一会话 | **只做**「GFC `cpe` 口直接进交换机、下面一堆 PC」。**全量环境测试排在该功能完成之后** |

**禁止重开：** proxy-ARP、管理 LAN 桥 isp/cpe、`auto_route`/`route.final`、学习 IP 写入 `TO_CN`/`bypass_ip`/`ext`/`ext_const`、MosDNS / sing-box DNS inbound、把 `default_interface` 全局写死 `br-trans`、veth 存在时再绑 `br-trans`（会掐 hitch RX）、从 `192.168.1.222:/root/sip-proxy` 打 OEM。

---

## 1. 新会话第一句（用户可整段粘贴）

```
严格按 docs/TRANSPARENT_MODE.md 与 docs/SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md。
本消息不是新开透明数据面，也不是全量验收。
下一步：规格增量「cpe 口直挂 L2 交换机、多台 PC」——先出规范 vs 实现差异表，
必须先改 TRANSPARENT_MODE.md + NFT_ARCHITECTURE.md（若动 netdev 链/set），
等我说「确认修改」并点名文件后再写代码。
禁止改 auto_route / route.final / unbound forward-zone / inet 表链 hook mark。
禁止把学习 IP 写入 TO_CN / bypass_ip / ext / ext_const。
不要回退 PE freeze，不要在 veth 存在时把 default_interface 写回 br-trans。
试编不升产品号。全量环境测试等本功能完成后再做。
```

---

## 2. 本里程碑相对旧契约：对照与结论

整体 packet flow / mark / TUN / unbound LAN `:53` **不变**。下列是刷含 `kmod-veth` 的 OEM 后实验室验证并写入代码的增量。

| 项 | 09-15 / SINGBOX 旧句 | 本里程碑（代码 + 实验室） | 架构冲突？ |
|----|----------------------|---------------------------|-----------|
| 偷流 RX | 产品 = veth `gfc-ce`/`gfc-ce-fwd`；无模块才 MAC-punt | **不变**。OEM 已有 `veth.ko`；探测口改为 `gfc-vp0`/`gfc-vp1`（IFNAMSIZ≤15）。旧名 `gfc-ce-fwd-probe` 16 字节会被 iproute2 拒绝，写 sticky `/tmp/gfc-veth-missing` | 无 |
| Client `bind_interface` | 透明省略 | **不变** | 无 |
| Client `default_interface` | 透明且 `br-trans` 存在 → **一律** `br-trans` | **分叉**：仅 MAC-punt（无 veth）才 `br-trans`；**`gfc-ce`+`gfc-ce-fwd` 存在则省略**（`SO_BINDTODEVICE br-trans` 收不到 hitch RX 在 `gfc-ce` 上的回程） | 无（不改 `final`/`auto_route`）。**SINGBOX_ARCHITECTURE.md 尚未改写** |
| `LiveMode` | env 优先于 `proxy-mode.json` | **pending → 已确认 JSON → env → cfg**。避免 agent 启动时残留 `GFC_PROXY_MODE=gateway` 盖过 Web 已确认的透明 | 无（设备 Web 权威） |
| PE MAC | isp 上声称 GW IP 的 ARP **后到覆盖** | **首次填入后冻结**。实验室：先学 `00:a5:27:e0:28:18`（能转发），后到 `70:70:fc:07:c2:3e`（vswitch/proxy-ARP）曾把邻居写成永久指向后者，223.5.5.5 与 VLESS 同时死 | 无。VRRP 真换 MAC **不会自动跟上**（见 §4） |
| unbound `outgoing-interface` | 透明绑 hitch dummy `172.31.253.1` | veth 存在时 **不写/剥掉**（绑 `gfc-ce` 会让本机 CN/DoT 出不去）。规范仍是 dummy bind；veth 例外在生成器 | 未获 SINGBOX/UNBOUND 文档合入；**禁止**改 `forward-zone` |
| 搭车 / 偷流回程 MAC | 一个主 CE + 一个 CPE MAC | **不变**。这就是下一会话要动的边界 | — |

`patch-singbox-wan.sh`（非 OpenWrt 主路径）透明时若存在 `br-trans` 仍写 `default_interface=br-trans`。OpenWrt 走 Go 生成器，不以该脚本为准。

---

## 3. 实验室已验证（本里程碑）

测试盒：`gfc-test` / 管理 LAN `192.168.68.1:212`。拓扑：**eth0=isp，eth1=cpe → 一台 VyOS CE**（CE 后面可以再接客户 LAN，电缆上仍只有一个 CE MAC/IP）。

通过项：

- veth `gfc-ce` / `gfc-ce-fwd` 存在；无 `/tmp/gfc-veth-missing`
- 透明 JSON：**无** `bind_interface`；**无** `default_interface`（veth 路径）
- `route.final=direct`；`auto_route` 未开
- 盒子 `drill`/`nslookup`：国内 A、国际 A；`wget ip.gs` 出 VLESS 公网
- PE 邻居锁在能转发的 MAC；agent 重启后 freeze 逻辑不再被后到 ARP 改写
- `LiveMode`：已确认 `proxy-mode.json=transparent` 不被进程内 stale env 盖掉

**未验证（不要写成已过）：**

- `cpe` 口直挂交换机、多台 PC 同时劫持 DNS / 国际 TCP
- PE 真 VRRP 换 MAC
- 网关 ↔ 旁路 ↔ 透明全切 + 确认超时回滚矩阵
- 正式 `pack-runtime` 制品给产线（盒子上是开发态安装）

---

## 4. PE 学错：已解决什么、还没解决什么

根因：规范只被动看 ARP——谁的以太网源 MAC 带着网关 IP，就把谁当 PE。旧实现 last-writer。isp 上两台设备同时声称 `192.168.88.1` 时，后到的会写成 **permanent neigh**，整条 WAN L2 断。

| 场景 | 本里程碑 |
|------|----------|
| 单光猫 / 单上联路由器，只有一个 MAC 答网关 ARP | 第一次学对就一直对（与改前相同） |
| 实验室 isp 上两个假网关（vswitch / 另一台设备 / proxy-ARP） | **已解决**：先填入的 PE MAC 不再被后续同 GW IP 的 ARP 覆盖 |
| 上联 VRRP / 主备换 MAC | **未做**：freeze 的代价。要靠邻居 FAILED 后再学，或 Web 锁定/重学。禁止改回 last-writer 来「顺便支持 VRRP」 |
| 正常现场 | 高发是实验室多假网关，不是单 PE |

实现：`gfc-client/internal/transparent/learn.go` `applyARP` RoleISP：`spa==GWIP` 时仅当 `PEMAC==""` 才写入。测试：`TestISPGatewayARPDoesNotRotateExistingPEMAC`。

CPE 侧 **仍然是 last-writer**（每帧 `st.CPEMAC = srcMAC`）。单 CE 稳定；交换机多 PC 会飘——这是下一会话的核心，不是本 tag 的 bug。

---

## 5. 单上联 + 多下联：当前版本有没有问题

规格原文（`TRANSPARENT_MODE.md` §4）：学主机不学网段；**搭车只用一个主 CE**；cpe 多主机时选正在 ARP 网关或流量最多者。§5.2：DNS/代理回程 `dst MAC = 这一个 CPE MAC`。`gfc-routing.sh` hitch SNAT 也只用一个 CE IP。

| 拓扑 | 电缆上能看到 | 本 tag |
|------|--------------|--------|
| 上联 1 台 PE，下联 **1 台路由型 CE**，交换机在 CE **后面** | 一个 CE MAC + 一个 CE IP | **已验证形态**。客户 LAN 交换机到不了 GFC 电缆 |
| 上联 1 台，下联 **交换机直接挂多台 PC** | 每台 PC 的 MAC/IP 都在 cpe 口 | **一期会有问题，不是漏测小补丁，是规格外 SKU** |

直挂交换机会出什么事（实现事实，供下一会话对照）：

1. **不偷的帧**（国内、ESP/IKE、非 53 UDP 等）L2 原样转发 → 一般还能过。
2. **劫持 DNS + 国际 TCP 偷流** 回程目的 MAC 写成当前学到的那一个 CPE MAC → 应答可能打到「最近说话的那台」，其它 PC 间歇失败。
3. **CPEMAC last-writer** 让「主 CE」跟着飘，比规格「选流量最多者」更差。
4. **本机 hitch** 仍 SNAT 成一个 CE IP 出 isp。多 PC 时选哪个 IP 当搭车地址是独立问题；即使回程 MAC 按流记住，盒子出站仍需要一个主 CE（除非规格改成「本机不搭车 / 另有出口」——**禁止擅自改**）。

下一会话要改的是 **2+3（以及是否仍全量偷每台 PC 的 53）**；不要顺手改 inet 分类或 hitch 五元组语义。

---

## 6. 代码与规范落点（本 tag）

| 文件 | 角色 |
|------|------|
| `gfc-client/deploy/immortalwrt/gfc-routing.sh` | veth 探测口 `gfc-vp0`/`gfc-vp1` |
| `gfc-client/internal/render/singbox/singbox.go` | 透明+veth → 省略 `default_interface`；Align 删除残留 |
| `gfc-client/internal/render/singbox/singbox_route_test.go` | `TestAlignBindWithProxyModeOmitsDefaultIfaceWhenVeth` |
| `gfc-client/internal/proxymode/store.go` | `LiveMode` 顺序 |
| `gfc-client/internal/proxymode/store_test.go` | committed/pending vs stale env |
| `gfc-client/internal/orchestrator/orchestrator.go` | apply 时 `LiveMode` + AlignBind |
| `gfc-client/internal/render/unbound/unbound.go` | veth 时跳过 hitch `outgoing-interface` |
| `gfc-client/internal/transparent/learn.go` | PE MAC freeze |
| `gfc-client/internal/transparent/learn_test.go` | 不旋转已有 PE |
| `gfc-client/deploy/patch-singbox-wan.sh` | 非 OpenWrt；透明仍可能写 `br-trans` |
| `docs/TRANSPARENT_MODE.md` | 下一步入口改指本文；记 PE freeze / veth omit |

**未提交、勿当规范：** `docs/draft/*`

**文档债（本 tag 未改 SINGBOX 全文，避免无批准改契约书）：** `SINGBOX_ARCHITECTURE.md` 多处仍写透明 `default_interface=br-trans`。下一会话若只改多主机，**不要**借机把 veth 路径改回 `br-trans`。用户确认后可把 §2 分叉写入 SINGBOX。

---

## 7. 下一会话：cpe 直挂交换机多 PC（开工清单）

### 7.1 这是规格增量，不是修 bug

现行 §4/§5.2 **明确一个主 CE + 一个回程 MAC**。要支持「电缆上很多主机」，必须先改规范再改生成器。未「确认修改」只读。

### 7.2 建议先拍板的产品句（供差异表，不是已批准实现）

把两件事拆开，避免一次重写 hitch：

| 流量 | 建议方向（待用户批） | 不要做成 |
|------|----------------------|----------|
| 客户原有、不 punt 的帧 | 继续 L2 一字不改 | 不要对整网做三层 |
| 偷来的 DNS / 国际 TCP **回给发起主机** | **按流记住入向以太网源 MAC**（或 IP→MAC 学习表有 timeout），回程 `dst MAC` 用该流的源，而不是全局 `CPEMAC` | 不要继续 last-writer 覆盖全局 MAC |
| 盒子本机出 isp（VLESS / unbound 上游） | **仍一个主 CE**（流量最多或 Web 指定）做 hitch SNAT + TX `src MAC=该主 CPE` | 不要给每台 PC 各做一份本机 SNAT；不要把学习 IP 写入 `bypass_ip`/`TO_CN` |
| CPEMAC 字段 | 主 CE 的 MAC 与「每主机 MAC」分开存 | 不要用全局 `cpe_mac` 既当 hitch 伪装又当所有回程 |

可选收窄（若用户要更小一期）：只保证 **DNS VIP 自愿入口** 多主机正确；「劫持每台 PC 的公网:53」放到二期。与现行「默认劫持全部递归 DNS」冲突时，**以用户对新规格的确认为准**，不得偷偷关劫持。

### 7.3 修改纪律

1. 读 `TRANSPARENT_MODE.md` §4–§8 与本文 §5。  
2. 输出规范 vs 实现差异表（当前一个 CPE MAC / 一个 hitch CE / last-writer）。  
3. 先写 `TRANSPARENT_MODE.md`；若动 `netdev gfc_trans` 链或 set，**先写 `NFT_ARCHITECTURE.md` §9.4**。  
4. 等用户 **「确认修改」** + 点名文件。  
5. 只改点名文件。禁止顺带改 inet 表/链/hook/mark、unbound `forward-zone`、sing-box `auto_route`/`route.final`。  
6. 试编不升 `PKG_RELEASE` / `vX.Y.Z`。

超出 09-09 已点名文件仍须另批。新 inet 表 **禁止**。

### 7.4 可能碰到的文件（确认前不要写）

- `docs/TRANSPARENT_MODE.md`、`docs/NFT_ARCHITECTURE.md` §9.4  
- `gfc-client/internal/transparent/learn.go`（停掉 CPE last-writer；主 CE vs 主机表）  
- `gfc-client/deploy/immortalwrt/gfc-routing.sh`（回程 `ether daddr set $learned_cpe_mac`；hitch 仍用主 CE）  
- 测试：`learn_test.go`；实验室：交换机下至少两台 PC 同时 `nslookup` + 一台国际 TCP

### 7.5 验收（仅多主机功能，不是全量）

- PC-A、PC-B 同时问被劫持的 53：各自收到应答，邻居不是对方 MAC  
- 不偷的国内流量两台都通  
- 盒子 VLESS/国内 223.5.5.5 仍走 **一个** 主 CE hitch，PE freeze 仍在  
- `sing-box.json`：veth 在则无 `default_interface`、无 `bind_interface`、`final=direct`

---

## 8. 量产仍缺（本 tag 之后、全量测试之前不必一次做完）

用户已定：**交换机多主机完成 → 再全量环境测试**。下列不要挤进下一会话，除非用户改口。

1. `pack-runtime.sh` 成为刷完新 OEM 后的标准步骤；禁止只刷 OEM 当含本 tag。  
2. PE：Web 展示已学 MAC；与邻居不一致告警；VRRP/FAILED 后再学（单独规格）。  
3. 产品文案：CPE **必须是路由型 CE** 直到多主机 SKU 交付。  
4. 三种模式切换确认超时回滚当验收项。  
5. 透明 Web：isp/cpe、DNS VIP、劫持开关、已学 CE/PE；平台只读。  
6. `SINGBOX_ARCHITECTURE.md` 写入 veth omit。  
7. 正式发版（矩阵 / CHANGELOG / `vX.Y.Z`）。现在 **禁止** 当量产版本对外。

一期规格本来没有、不要当成出货阻塞：IPv6、拦 DoH/DoT、proxy-ARP 档。

---

## 9. 环境与探针

SSH：`gfc-test` = 盒子；`gfc-runtime` = `192.168.1.222` **只编 runtime**。OEM 构建机 `gfcbuild@192.168.0.185` `/opt/gfc`。不要从 222 打 OEM。

新 OEM 已含 `kmod-veth`；本 tag 是 runtime。更新盒子：在含本 tag 的仓库 `pack-runtime`，不要重刷旧 OEM。

```sh
# veth 主路径（取代 09-15「透明必须 default_interface=br-trans」）
python3 - <<'PY'
import json
c = json.load(open("/etc/gfc-client/sing-box.json"))
assert c["route"]["final"] == "direct"
trans = "GFC_PROXY_MODE=transparent" in open("/etc/gfc-client/gfc.env").read()
di = c["route"].get("default_interface")
binds = [o.get("bind_interface") for o in c["outbounds"] if isinstance(o, dict)]
import os
veth = os.path.exists("/sys/class/net/gfc-ce") and os.path.exists("/sys/class/net/gfc-ce-fwd")
if trans:
    assert not any(binds), binds
    if veth:
        assert not di, di
    else:
        assert di == "br-trans", di
print("sing-box iface OK", "veth" if veth else "mac-punt", di)
PY
lsmod | grep '^veth'
ip -d link show gfc-ce | head
test ! -e /tmp/gfc-veth-missing
# PE freeze
python3 -c "import json;print(json.load(open('/etc/gfc-client/transparent-learned.json')).get('pe_mac'))"
ip neigh show | grep 192.168.88.1 || true
```

---

## 10. 用户口令

> 严格按 `docs/TRANSPARENT_MODE.md` 与 `docs/SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md`。下一会话只做 cpe 直挂交换机多 PC：先差异表，先改规范（及必要的 `NFT_ARCHITECTURE.md` §9.4），确认后再写点名文件。不要回退 PE freeze；veth 存在时不要写 `default_interface=br-trans`。禁止改 `auto_route` / `route.final` / inet 表链 hook mark。试编不升号。全量测试等该功能完成后再做。
