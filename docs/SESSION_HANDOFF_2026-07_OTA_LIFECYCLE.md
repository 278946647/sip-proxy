# 会话交接：OTA / 线路生命周期 / VLESS 诊断（2026-07-16）

> 写给**无本对话上下文**的新会话与构建机验收。  
> Cursor 规则：[`.cursor/rules/gfc-platform-ota-lifecycle.mdc`](../.cursor/rules/gfc-platform-ota-lifecycle.mdc)  
> 固件构建仍以 [`gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md`](../gfc-client/deploy/immortalwrt/FIRMWARE-BUILD-HANDOFF.md) 为准。

---

## 0. 一句话状态

| 面 | 状态 | 关键 commit（约） |
|----|------|------------------|
| 控制面：线路/设备生命周期 | **已完成并 push** | `43f2f85`、`9425335` |
| 控制面 + 客户端：Runtime OTA 一期 | **已完成并 push** | `180a87d`、`c429916` |
| 客户端：VLESS 出口检测（SOCKS 感知） | **已完成并 push** | `43402db` |
| 固件包版本 | 源码已升 **`gfc-client 1.1.0-r15`**（含本批客户端能力）；**须重建镜像**后 manifest 才变 |

---

## 1. 本会话完成了什么

### 1.1 线路 / 客户端生命周期（控制面 + agent）

- 线路删除：有绑定客户端时 **禁止删**
- 设备名：首次用 TID；管理员改名后 **`name_source=admin`**，heartbeat 不得覆盖
- **软重置**：清线路码、保留托管；UI 标签「托管·待分配」；危险确认
- **硬退役**：须先软重置；tombstone + 反向端口冷却；可按 `device_key` reclaim
- agent：无 activation 文件但有 token 时可继续托管心跳

### 1.2 Runtime OTA（一期）

- 控制台：**系统设置** 总览 → 升级制品 / 平台安全详情 / 邮件详情
- 设备详情：**单设备**下发升级命令
- 表/API：`runtime_artifacts`；admin CRUD；client 下载；heartbeat `runtime_upgrade`
- 客户端 LuCI：`GFC终端网关 → 配置运维 → 系统版本升级`（平台拉包 + 本地上传 + 进度）
- Vue 维护页对齐；本地 `apply-file` / 路径安装
- 老盒子策略：**先人工 install.sh 打底，再 OTA**；新能力随下次编镜像带上（不强制本期全量刷机）

### 1.3 Auth Secret 产品结论（未改代码，已定调）

- Auth Secret **必须存在**（签 Web 会话）
- **不宜**在设置页日常手填；宜「已配置」+ 应急一键轮换（后续可做）
- 管理员密码改用户管理即可

### 1.4 VLESS 隧道出口检测

- 直联 IP：国内站 `ip.3322.net`、`members.3322.org/dyndns/getip`、`http://ip.plus`（解析 `IP: x.x.x.x 来自...`），`--interface WAN`
- 隧道出口：境外站（ip.gs 等），默认路由
- 比对：出口=直联 → 未接管；否则命中 **SOCKS 配置 IP 或 转发节点 IP** → 通过；出口探测失败 → 隧道异常

---

## 2. 后续开发必须遵循

1. **nft / unbound / sing-box**：未获用户「确认修改」**禁止改代码**（见对应 `*-no-change-without-approval.mdc`）。
2. **OTA 一期范围**：单设备下发；不做批量编队、不做 fake-ip/DNS 替代 unbound。
3. **固件进包**：改 `gfc-client` / `luci-app-gfc` 源码后 **必须 bump `package/Makefile` 的 `PKG_RELEASE`**，否则 manifest 仍显示旧 rN，无法用版本号区分。
4. **构建机 git**：若 `dubious ownership`，用 `git config --global --add safe.directory /opt/gfc/sip-proxy`，或改用仓库属主用户（`gfcbuild`）操作；勿随意 `chown -R root`。
5. **部署控制面**：`git pull` 后重建 **api + web**；`GFC_ARTIFACTS_DIR=/data/artifacts`。
6. **盒子验 OTA**：需新二进制（或 r15+ 固件）+ LuCI `upgrade.js`；仅刷旧镜像看不到新菜单逻辑。

---

## 3. 踩过的坑（禁止再踩）

| 坑 | 正确做法 |
|----|----------|
| 以为 `luci-app-gfc …~43402db` 就等于 `gfc-client` 包版本也升了 | **两套版本**：LuCI 用 git 描述；`gfc-client` 用 `PKG_VERSION-rPKG_RELEASE`。只看 luci hash 不够。 |
| 源码已合 OTA/诊断，manifest 仍是 r14 | **未 bump PKG_RELEASE**；或重建用的不是最新 `git pull` / 未清旧 staging。 |
| 用境外站测 `direct_ip`（ipify）导致空 | 直联必须用**国内落地** URL + WAN 绑口。 |
| VLESS 检测只比转发节点 IP | 有 SOCKS 时出口是 SOCKS；须 OR 比对。 |
| 改 Auth Secret 当日常配置 | 会踢光 Web 会话；勿与 Bootstrap Token 混为同级日常项。 |
| OTA 同步 HTTP 安装导致 LuCI wget 超时 | 安装须**异步** + `/upgrade/status` 轮询进度。 |
| `git pull` 用 root 操作属主为 gfcbuild 的树 | `safe.directory` 或切用户。 |
| 控制面只升 web 不升 api（或相反） | OTA / 生命周期需 **api+web** 同发。 |

---

## 4. 如何确认固件 / 运行中版本「是最新」

### 4.1 构建机（编完立刻查）

```bash
export IMT_SRC=/opt/gfc/immortalwrt
# 1) 包版本（权威）
grep -E 'gfc-client|luci-app-gfc' "$IMT_SRC/bin/targets/x86/64/"*.manifest

# 期望（本批之后）：
#   gfc-client - 1.1.0-r15
#   luci-app-gfc - 26.197.…~<git短哈希>   # 哈希应 ≥ 含功能的 commit（如 43402db）

# 2) 仓库是否最新
cd /opt/gfc/sip-proxy && git rev-parse --short HEAD && git log -1 --oneline

# 3) 源码 PKG_RELEASE 是否与 manifest 一致
grep PKG_RELEASE gfc-client/deploy/immortalwrt/package/Makefile
```

**你这次看到 `gfc-client - 1.1.0-r14` 且 luci `~43402db`：**  
说明 LuCI 已编进 `43402db` 附近源码，但 **`gfc-client` 的 OpenWrt 包发布号当时仍是 14**，不能据此说「没有最新 Go 代码」——要以 **二进制是否含符号/接口** 再验（见下）。从本仓库 bump 到 **r15** 后，请再 `git pull` + `rebuild-gfc-image.sh`，manifest 应变为 **r15**。

### 4.2 已刷机的盒子（功能验收）

```bash
opkg list-installed | grep -E 'gfc-client|luci-app-gfc'
# 可选：看本地 VERSION
cat /usr/lib/gfc-client/VERSION 2>/dev/null; cat /opt/gfc-client/VERSION 2>/dev/null

# OTA API 是否存在
wget -qO- http://127.0.0.1:8080/api/v1/upgrade/status

# VLESS 诊断是否返回新字段
wget -qO- --post-data='{}' --header='Content-Type: application/json' \
  http://127.0.0.1:8080/api/v1/diagnostics/vless | head
# 应含 expected_ip / socks_ip / outbound_mode / direct_source 等
```

LuCI 菜单：**配置运维 → 系统版本升级**（平台升级区 + 本地上传 + 进度条）。  
**故障诊断 → 连通性检测 → VLESS 隧道出口检测**（结论含 SOCKS/节点比对说明）。

### 4.3 控制面 OTA 联调（与固件独立）

控制面需已部署含 artifacts 的 api/web；盒子需已激活（有 client token + `SERVER_URL`）。  
未激活时平台拉包会失败，**本地上传仍应可用**。

---

## 5. 建议的新会话开场白

> 读 `docs/SESSION_HANDOFF_2026-07_OTA_LIFECYCLE.md` 与 `.cursor/rules/gfc-platform-ota-lifecycle.mdc`。
> OTA/生命周期/VLESS 诊断已在 main；固件以 manifest **`gfc-client 1.1.0-r16`**（产品 **v1.1.1**）与功能探针为准；OTA 验收见 `docs/releases/notes/v1.1.1.md`。
> 改 nft/unbound/sing-box 须确认修改；改 PKG 进镜像必须 bump `PKG_RELEASE`。

---

## 6. 关键路径速查

| 能力 | 路径 |
|------|------|
| 制品 API | `gfc-platform/control-plane/api/app/artifacts.py` |
| 设置 UI | `gfc-platform/web-ui/src/pages/Settings*.tsx` |
| 客户端升级 | `gfc-client/internal/upgrade/`、`internal/api/server.go` |
| LuCI 升级页 | `luci-app-gfc/.../view/gfc/upgrade.js` |
| VLESS 诊断 | `gfc-client/internal/api/vless_diag.go` |
| 包版本 | `gfc-client/deploy/immortalwrt/package/Makefile` |
