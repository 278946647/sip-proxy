# 会话交接：透明实验室闭环 · sing-box 口对齐 · OEM veth（2026-09-15）

> 写给**无本对话上下文**的新会话：**先读本文再推进**。  
> **产品唯一真相：** [`TRANSPARENT_MODE.md`](TRANSPARENT_MODE.md)  
> **nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) §9.4  
> **sing-box：** [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md)  
> **一期实现批准（表名）：** [`SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-09-09_TRANSPARENT_MODE.md)  
> 规格讨论冻结（勿当开工清单）：[`SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md`](SESSION_HANDOFF_2026-08-31_TRANSPARENT_MODE.md)  
> Cursor：`.cursor/rules/transparent-mode.mdc` / `singbox-no-change-without-approval.mdc` / `gfc-firmware-build.mdc`  
> 版本：[`VERSION_AND_RELEASE.md`](VERSION_AND_RELEASE.md) §1.5 — **试编不升产品号**

---

## 0. 一句话状态

| 面 | 状态 |
|----|------|
| 实验室（旧 OEM，无 `veth.ko`） | **CPE DNS / Web / hitch TCP / 盒子 unbound 已通过** |
| 规范 | **已对齐**（见 §2）；无整体架构冲突 |
| Client sing-box JSON | **已改生成器**：透明 `default_interface=br-trans`；切走恢复 WAN |
| OEM `kmod-veth` | **选包与 ORIG 门禁已有**；测试盘是旧镜像，**尚未重编刷入** |
| 产品 `vX.Y.Z` / `PKG_RELEASE` | **未升**（§1.5） |
| Git | `milestone/transparent-lab-20260915` = 无 veth 的 DNS 闭环；本交接 HEAD 另打研发 tag |

**禁止重开：** proxy-ARP、管理 LAN 桥 isp/cpe、`auto_route`/`route.final`、学习 IP 写入 `TO_CN`/`bypass_ip`/`ext`/`ext_const`、MosDNS / sing-box DNS inbound、全局写死 `br-trans`、从 `192.168.1.222:/root/sip-proxy` 打 OEM。

---

## 1. 新会话第一句（用户可整段粘贴）

```
严格按 docs/TRANSPARENT_MODE.md 与 docs/SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md。
本消息不是新开透明规格。下一步：gfcbuild 构建机试编 OEM（必须 kmod-veth 进 manifest+ORIG），再打 runtime 装到 gfc-test，验收 veth 路径与 sing-box JSON。
禁止改 auto_route / route.final / unbound forward-zone / inet 表链 hook mark。
试编不升产品号。不要从 192.168.1.222 /root/sip-proxy 打 OEM。
```

---

## 2. 本会话相对旧契约：对照与结论

整体 packet flow / mark / TUN / unbound LAN `:53` **不变**。下列是实验室验证后写入规范的增量（不是另起架构）。

| 项 | 旧契约（09-09 / 改前 SINGBOX） | 本会话拍板（已写入规范） | 架构冲突？ |
|----|-------------------------------|--------------------------|-----------|
| 偷流层 | `netdev gfc_trans`；产品 RX = veth `gfc-ce`/`gfc-ce-fwd` | **不变**。无 `kmod-veth` 时允许 MAC-punt 到 **br-trans MAC** + `tc` ingress `skbedit ptype host`（cpe UDP/53）。**禁止** `nft fwd` 到 ifb | 无（回退，不改表名） |
| DNS trampoline | `sport 53 return` 先于 hitch SNAT | **加严**：CE `/32` 必须 `src <dns_vip>`；trampoline 在 `ct original ip daddr` 已是 CE 时 **跳过** | 无 |
| hitch 回程 | conntrack reverse-SNAT；禁止手工 daddr-CE DNAT | **不变** | 无 |
| Client `bind_interface` | 透明省略 | **不变** | 无 |
| Client `default_interface` | 一律运行时 WAN（常为 isp 从口 `eth0`） | **仅透明且 `br-trans` 存在** → `br-trans`；网关/旁路仍 WAN | 无（不改 `final`/`auto_route`） |
| 切模式 JSON | Align 只剥透明 bind，切走 no-op | Align 双向：透明剥 bind + `br-trans`；切走恢复 WAN bind + WAN `default_interface` | 无 |
| OEM 模块 | 选包已有 dummy/netdev/veth 门禁 | **强制**：新盘 ORIG 必须有 `veth.ko`。runtime 包 **带不上** `.ko` | 无 |
| 产品默认偷流 RX | veth | **仍是 veth**。MAC-punt+tc **不是**长期产品主路径 | 无 |

---

## 3. 实验室已验证（旧镜像，无 veth）

测试盒：`gfc-test` / `192.168.68.1:212`（管理 LAN）。拓扑：eth0=isp，eth1=cpe → VyOS CE。

通过项：

- `dual` + hitch TCP（含 wget :8181）
- 盒子 unbound；CPE `nslookup`（VIP 与劫持公网 53）；CPE Web
- 无 `veth.ko`：MAC-punt + `tc qdisc ingress` `u32 dport 53` → `skbedit ptype host`（tc 在 nft netdev **之前**）
- CE 路由 `src` DNS VIP，避免应答变成 `src=CE dst=CE`

已知限制（刷含 veth 的新 OEM 后应消失）：

- `/tmp/gfc-veth-missing` 一旦写下，本次启动不再重试 veth
- `br-trans` `rx_otherhost` 在 MAC-punt 路径会爬升；veth `fwd` 产生 HOST，不需要 skbedit

---

## 4. 代码与规范落点

| 文件 | 角色 |
|------|------|
| `docs/TRANSPARENT_MODE.md` | 透明产品真相；§8 sing-box 口；CE src VIP；OEM veth |
| `docs/NFT_ARCHITECTURE.md` §9.4 | 无 veth 回退、trampoline 跳过 CE、CE 路由 src VIP |
| `docs/SINGBOX_ARCHITECTURE.md` | `default_interface` 按 `proxy_mode`；Align 切模式 |
| `gfc-client/internal/render/singbox/singbox.go` | `resolveRouteIface` + `AlignBindWithProxyMode` |
| `gfc-client/internal/orchestrator/orchestrator.go` | 重渲染后 Align |
| `gfc-client/deploy/immortalwrt/gfc-routing.sh` | 无 veth DNS 交付（已在 `milestone/transparent-lab-20260915`） |
| `gfc-client/deploy/immortalwrt/config/gfc-packages.config` | `CONFIG_PACKAGE_kmod-veth=y`（早已选中） |
| `rebuild-gfc-image.sh` | ORIG 缺 `veth.ko` **构建失败** |

**未提交、勿当规范：** `docs/draft/*`

---

## 5. 新会话下一步（按顺序）

1. **OEM（gfcbuild @ `/opt/gfc`，不是 `192.168.1.222`）**  
   `git pull` 到本交接 HEAD → `rebuild-gfc-image.sh`（**不要** `GFC_SKIP_KERNEL_REFRESH=1`，**不要** `GFC_PUBLISH_RELEASE=1`，**不要** bump `PKG_RELEASE`）。  
   验收：`*.manifest` 含 `kmod-veth`；ORIG 有 `veth.ko`。
2. **刷测试盘**（`*ext4*combined*efi*.img.gz`）。
3. **runtime**：在已同步本提交的仓库打 `pack-runtime.sh`，装到 `gfc-test`。禁止用构建机上停在旧 hash 的 `/root/sip-proxy` 打包。
4. **验收 veth 主路径**  
   `lsmod | grep veth`；`ip -d link show gfc-ce` 为 veth；无 `/tmp/gfc-veth-missing`；`sing-box.json` 透明时 `default_interface=br-trans` 且无 `bind_interface`；切回网关后恢复 WAN bind。
5. 再跑 `TRANSPARENT_MODE.md` §11 与 `verify-dataplane-dns.sh`。

SSH 别名（Windows）：`gfc-test` = 盒子；`gfc-runtime` = `192.168.1.222` **只编 runtime**。本机当时 **没有** OEM 构建机 SSH。

---

## 6. 验收探针（JSON / 模块）

```sh
python3 - <<'PY'
import json
c = json.load(open("/etc/gfc-client/sing-box.json"))
assert c["route"]["final"] == "direct"
mode = open("/etc/gfc-client/gfc.env").read()
trans = "GFC_PROXY_MODE=transparent" in mode
di = c["route"].get("default_interface")
binds = [o.get("bind_interface") for o in c["outbounds"] if isinstance(o, dict)]
if trans:
    assert di == "br-trans", di
    assert not any(binds), binds
else:
    assert di and di != "br-trans", di
print("sing-box iface OK", di)
PY
lsmod | grep '^veth'
find /lib/modules/$(uname -r) -name 'veth.ko*'
ip -d link show gfc-ce | head
```

---

## 7. 用户口令

> 严格按 `docs/TRANSPARENT_MODE.md` 与 `docs/SESSION_HANDOFF_2026-09-15_TRANSPARENT_LAB.md`。只改点名文件。OEM 必须含 `kmod-veth`。透明 sing-box `default_interface` 仅 `br-trans`（口存在时），网关/旁路 WAN。试编不升号。
