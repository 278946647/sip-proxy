# 会话交接：透明 hitch 方案 A/B 拍板（2026-09-17）

> 写给**无本对话上下文**的新会话：**先读本文再写代码**。  
> **产品唯一真相：** [`TRANSPARENT_MODE.md`](TRANSPARENT_MODE.md) §1.1、§2 #21、§4.2、§4.3  
> **nft：** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) §9.4 hitch identity `<hitch_ip>` / `<hitch_src_mac>`  
> **上一里程碑：** [`SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md`](SESSION_HANDOFF_2026-09-16_TRANSPARENT_VETH_RUNTIME.md)  
> 版本：[`VERSION_AND_RELEASE.md`](VERSION_AND_RELEASE.md) §1.5 — **试编不升产品号**

---

## 0. 一句话

用户已拍板：下联关机/待机（cpe 口仍 up）**继续伪装 CE**（方案 A）；**拔线或从未学到**才用备用管理 IP（方案 B）；切回 make-before-break，动作 ≤200ms，心跳/VLESS 允许重连约 1s。

**本批只改了规范。生成器未写。** 须用户回复「确认修改」并点名文件后才能动代码。

---

## 1. 新会话口令

```
严格按 docs/TRANSPARENT_MODE.md §1.1 §2#21 §4.2 §4.3 与 docs/NFT_ARCHITECTURE.md §9.4。
方案 A：单下联关机/待机不拆 hitch；who-has 主 CE 仅在另有新鲜主机时改选。
方案 B：仅 cpe operstate down 或从未学到；备用 IP 本机 MAC；答备用 ARP、不答 CE。
切回：cpe up + 下联第一帧；先 hitch 再撤备用；防抖 ≤200ms。
禁止空闲定时器切 B。禁止新 inet 表。禁止改 auto_route / route.final / hook / mark。
试编不升号。点名文件见交接 §3，确认修改后再写。
```

---

## 2. 规范 vs 实现（写代码前对照）

| 项 | 规范（已拍板） | 当前实现 | 差距 |
|----|----------------|----------|------|
| 唯一下联 + 上联 who-has CE ×5 | **保持 hitch** | `learn.go` `CEMiss>=5` 即清空主 CE | **bug vs 新规范** |
| 多 PC + who-has 死 CE + 另有新鲜主机 | 改选 hitch | 同上，有第二主机时会改选 | 与 ① 仍一致 |
| `refresh-trans` 防抖 | 身份切换 ≤200ms | `refreshDebounce=2s` | gap |
| 备用管理 IP | Web 可配；B 时 SNAT+本机 MAC+答 ARP | **无** | 未做 |
| cpe 口 down | 切 B（若已配置） | 无 link watch | 未做 |
| 切回 | 第一帧后 make-before-break | 无 | 未做 |
| 旧 CE `/32` 残留 | 换身份须删旧地址 | `apply_trans_addrs` 只 replace | 已知债 |
| inet 表/链/hook/mark | 不变 | 不变 | — |

---

## 3. 确认修改后点名文件（未确认不得写）

**方案 A（可先做）：**

- `gfc-client/internal/transparent/learn.go`
- `gfc-client/internal/transparent/learn_test.go`

**方案 B + 切回 + 防抖（A 之后）：**

- `gfc-client/internal/transparent/types.go`（备用 IP 落盘）
- `gfc-client/internal/transparent/supervisor.go`（口 down / 第一帧；防抖）
- `gfc-client/deploy/immortalwrt/gfc-routing.sh`（`<hitch_ip>` SNAT / MAC；旧 `/32` 删除）
- `gfc-client/internal/proxymode/` + `gfc-client/internal/api/proxymode.go`（Web 字段）
- 设备 Web 设置页（与 LuCI 双轨须一致的那份）

禁止顺带：`auto_route`、`route.final`、inet 表链 hook mark、unbound `forward-zone`、升产品号。

---

## 4. 术语（勿再混）

本机 = GFC 盒子。CE = 下联 **IP**。CPE MAC = 下联 **MAC**。PE/GW = 上联。管理 LAN ≠ 客户电缆。单 PC 时 CE 与 CPE 是同一台机器。
