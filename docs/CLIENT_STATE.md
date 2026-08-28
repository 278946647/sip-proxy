# GFC Client 状态落盘与启动再应用（权威）

**Status:** 仓库内客户端状态拓扑与 `ReapplyLocal` / 生命周期的唯一真相。  
**Scope:** GFC Client（ImmortalWrt / Ubuntu）。不覆盖 nft 表链、unbound 模板、sing-box JSON 生成器。  
**Companion:** [`NFT_ARCHITECTURE.md`](NFT_ARCHITECTURE.md) · [`UNBOUND_ARCHITECTURE.md`](UNBOUND_ARCHITECTURE.md) · [`SINGBOX_ARCHITECTURE.md`](SINGBOX_ARCHITECTURE.md) · [`gfc-client/docs/ARCHITECTURE.md`](../gfc-client/docs/ARCHITECTURE.md)（路径树须与本文一致）

若实现与本文冲突，**实现是 bug**，不得改本文迁就代码。

---

## 1. 为什么 OpenWrt 不能用 `/var/lib`

ImmortalWrt / OpenWrt 上 `/var` → `/tmp`（tmpfs）。把 `config_bundle.json` 与 `client_state.json`（token）放在 `/var/lib/gfc-client` 时，**重启即丢失**。Agent 启动时 `ReapplyLocal` 见不到 bundle，会 `BootstrapIdle()` 把仍在 overlay 上的带 TUN 的 `sing-box.json` 写成空 `inbounds`，`gfctun` 消失。

Ubuntu 的 `/var/lib` 在磁盘上，保持 `/var/lib/gfc-client`。

---

## 2. 路径契约

| 平台 | `GFC_LIB` 默认 | 介质 |
|------|----------------|------|
| ImmortalWrt / OpenWrt | **`/etc/gfc-client/lib`** | overlay 持久 |
| Ubuntu / 通用 Linux | `/var/lib/gfc-client` | 磁盘 |

显式 `GFC_LIB` 指向**非** `/var/lib/gfc-client`、`/tmp/lib/gfc-client` 的路径时，以环境变量为准（测试/定制）。  
OpenWrt 上若环境或 `gfc.env` 仍为 `/var/lib/gfc-client`，视为 volatile，**必须 remap** 到 `/etc/gfc-client/lib`。

| 类 | 路径 | 内容 |
|----|------|------|
| 配置 / 渲染 | `/etc/gfc-client/` | `gfc.env`、`activation.b32`、`platform.b32`、`sing-box.json`、`dataplane-mode.json`、unbound 渲染产物、`policy-routing/` |
| **状态库** | `$GFC_LIB` | `state/config_bundle.json`、`state/client_state.json`、`state/ota-result.json`、`gfc-client.db`、`rules/`、`dns-lists/`、`backups/` |
| 日志 | `/var/log/gfc-client`（OpenWrt 常为 tmpfs） | 可丢 |

**迁移：** 启动时若新 `GFC_LIB` 缺文件、旧 `/var/lib/gfc-client` 或 `/tmp/lib/gfc-client` 有，则 **只拷不覆盖**。

**禁止：**

- 在 OpenWrt 把 bundle / token 默认写回 `/var/lib/gfc-client`
- 用「缺 bundle」当作出厂重置去 idle 覆盖仍带 TUN 的 json
- 因状态路径改动而改 `auto_route` / `route.final` / nft 表名链名 / unbound listen

---

## 3. 启动再应用（`ReapplyLocal`）

| 条件 | 行为 |
|------|------|
| 有合法 bundle 且非 direct | 按 bundle `applyPayload` |
| 无 bundle，且 `dataplane-mode.json` 的 `mode=active` **且** `sing-box.json` 含 `type=tun` inbound | **保险丝：** 不写 `IdleConfig()`；保留 last-good TUN；可重启 dataplane 服务 |
| 无 bundle，且无 last-good TUN | `BootstrapIdle()`（空 `inbounds`，无 `gfctun`） |
| 明确 `BootstrapIdle()` / `ApplyDirect` / 出厂 `Clear()` | 仍写 idle |

`ReloadDNS` 在 bundle 缺失且 last-good TUN 存在时：**不得** `BootstrapIdle()`。

---

## 4. 生命周期

| 操作 | 删除 | 数据面 |
|------|------|--------|
| 刷新线路码 `Flash` | 可选只清 token；**不**因换码删 bundle | 激活成功 `ApplyPayload` **覆盖** bundle + json |
| 平台 409「已绑别的线路」 | 不删本地 bundle | 保留**当前已绑线路**的 TUN，等平台解绑/重绑后再激活 |
| 软重置 `ClearLineCode` | 只删 `activation.b32` | token + bundle + TUN 保留 |
| 出厂 `Clear()` | `activation`、`platform`、**token、bundle**，再 `BootstrapIdle` | idle。**持久化后若不删 bundle，重启会把旧线路配回去** |
| 硬退役 / 401 | 清 token（现网） | 拉到新配置才换 json |

换新线路码 **不会** 被 §2/§3 误伤：成功激活仍覆盖配置；409 时保留旧 TUN 是因为平台仍绑旧线路。

---

## 5. 实现对齐

| 组件 | 位置 |
|------|------|
| `GFC_LIB` 解析 / 迁移 | `gfc-client/internal/config/config.go`、`deploy/immortalwrt/lib-gfc-paths.sh` |
| `ReapplyLocal` 保险丝 | `gfc-client/internal/orchestrator/orchestrator.go` |
| 出厂删 bundle | `gfc-client/internal/activation/activation.go` `Clear()` |
| Agent / API `GFC_LIB` | `deploy/immortalwrt/package/files/etc/init.d/gfc-agent`、`gfc-api` |
