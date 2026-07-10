# GFC 反向远程管理 — 会话交接（HANDOFF）

> 写给**完全没有上下文**的新对话。最后更新：2026-07-10。  
> 仓库：`sip-proxy`（GFC 企业边缘网关 + 控制平台 `gfc-platform` + 客户端 `gfc-client`）。

---

## 1. 本阶段在做什么任务

从控制平台对 **NAT 后面的 ImmortalWrt 客户端** 做 **按需反向 SSH 远程管理**，提供三类入口：

| 入口 | 客户端目标 | 控制平台侧 |
|------|------------|------------|
| **远程 SSH** | 盒子 dropbear `:212` | WebSSH → `127.0.0.1:P` |
| **Web 管理** | uhttpd `:80` LuCI | HTTP 反代 `/remote/{id}/luci/...` |
| **刷码协助** | `:80` `/gfc/activate.html` | HTTP 反代 `/remote/{id}/flash/` |

**架构定稿（勿改除非架构评审）：**

- 控制平台 = 公网堡垒 + 反代入口（`sshd :212` 收 autossh）
- 客户端 **outbound** `autossh -R` 到 CP，映射到 CP `127.0.0.1` 端口池
- **按需建连**：管理员点击后才下发会话（TTL ~30min），非常开隧道
- 端口池：**6001–7999**，每设备 **2 端口**：`P`=SSH，`P+1`=HTTP(80)
- 客户端生成 `reverse_ssh_id`（ed25519），**仅上传公钥**；私钥不出设备

**明确不做：** frp、线路码里写私钥、反代到盒子 `:8080` gfc-api。

---

## 2. 已经完成了什么（代码 + 文档）

### 2.1 控制平台（`gfc-platform/`）

| 能力 | 状态 | 关键文件 / 提交 |
|------|------|-----------------|
| DB 迁移（`reverse_http_port`、`ssh_public_key`、会话字段） | ✅ | `migrate.py` |
| 顺序端口分配 | ✅ | `reverse_ssh.py` |
| 心跳下发 `reverse_ssh` 指令 + 收公钥/隧道状态 | ✅ | `clients.py` |
| 会话 API `POST/GET/DELETE .../reverse-ssh/session` | ✅ | `admin.py` |
| `authorized_keys` 渲染（gfc-reverse 用户） | ✅ | `reverse_ssh.py` |
| HTTP 反代 LuCI/flash | ✅ | `remote_proxy.py` |
| WebSSH WebSocket | ✅ | `webssh.py` |
| nginx `/remote/` + `/api` WebSocket | ✅ | `web-ui/nginx.conf` |
| sshd 入站端口默认 **212** | ✅ | `settings.py` |
| 老设备心跳时 **补分配端口** | ✅ | `cc787fa` |
| API **host 网络** + 宿主机 `authorized_keys` 目录挂载 | ✅ | `40088ed`, `56addc8` |
| `setup-reverse-ssh.sh`（gfc-reverse 用户 + sshd Match） | ✅ | `deploy/control/setup-reverse-ssh.sh` |
| WebSSH 路由修复（不用 `#/`） | ✅ | `0fb5aa2` `openRemote.ts` |
| **WebSSH 自动密钥**：CP 生成 `/data/pki/webssh_id`，心跳下发 `webssh_authorized_key` | ✅ | `4fd9ae1` `webssh_keys.py` |

### 2.2 客户端（`gfc-client/`）

| 能力 | 状态 | 关键文件 / 提交 |
|------|------|-----------------|
| `reversessh` 模块：密钥、解析心跳、autossh | ✅ | `internal/reversessh/reversessh.go` |
| OpenWrt wrapper `/usr/lib/gfc-client/reverse-ssh-run.sh` + procd init | ✅ | `553be72` 等 |
| `autossh` 路径动态解析（`/usr/sbin/autossh`） | ✅ | |
| 去掉 `ServerAliveCountMax`（dropbear ssh 不支持） | ✅ | |
| 启动后验证进程 / ssh 探测 | ✅ | |
| 心跳上报 `reverse_ssh_status.active`（pidof 兜底） | ✅ | `runner.go` |
| **安装 CP WebSSH 公钥到 dropbear** | ✅ | `websshauth.go` `4fd9ae1` |

### 2.3 Web UI

- 客户端列表/详情：远程 SSH、Web 管理、刷码协助按钮
- `ClientWebSSHPage`：WebSocket 终端
- 列表已去掉重复「线路码」、详情去掉网络速率卡片（`e235acc`）

### 2.4 已在真实环境验证通过的

- ImmortalWrt 手动跑 `/usr/lib/gfc-client/reverse-ssh-run.sh` 后，Ubuntu 上 `ssh -p 6080 root@127.0.0.1` **能进盒子 shell**（需 root 密码或已装 WebSSH 公钥）
- `gfc-reverse@CP:212` 公钥认证 + `-R 127.0.0.1:6080:127.0.0.1:212` 隧道建立（Ubuntu `ss` 见过 `127.0.0.1:6080` LISTEN）
- WebSSH **页面路由**修复后应打开 `/client-devices/:id/ssh`，不再是仪表盘

---

## 3. 当前卡在哪（截至交接时）

### 3.1 生产/测试环境未完全对齐最新代码

| 组件 | 问题 |
|------|------|
| **ImmortalWrt agent** | 现场多为 **旧 `gfc-agent`**（如 v1.1.0 / PID 18589）：每 10s 心跳可能 **覆盖** `/etc/init.d/gfc-reverse-ssh`、误报 `reverse ssh :6080 -> ...` 成功、**不会**写 WebSSH 公钥到 dropbear |
| **控制平台 API** | 需部署 `4fd9ae1`+ 才有 `/data/pki/webssh_id` 与心跳 `webssh_authorized_key`；需 **host 网络** 才能 `probe 127.0.0.1:6080` |
| **控制平台 Web** | 需重建 web 镜像才有 `openRemote` 路径修复 + WebSSH UI 文案 |
| **WebSSH UI** | 曾出现 `Permission denied`：WebSSH 用 BatchMode 连 `root@127.0.0.1:6080`，盒子 dropbear 要密码；**自动密钥流程已编码但未在盒子落地**（需新 agent 心跳） |
| **按需隧道** | UI `waitForTunnel` 依赖 CP 上 `6080` LISTEN + 会话 `tunnel_ready`；隧道需 **点击远程 SSH 后** 由 agent 拉起，或临时手跑 runner |

### 3.2 未自动化的运维项

- 客户端盒子 **不会**因只更新 CP 源码而升级；必须 **单独编译/安装 `gfc-agent`**
- `docker-compose` **1.29** 在 Ubuntu 上 recreate web/api 易报 `KeyError: 'ContainerConfig'`
- 用户环境命令是 **`docker-compose`**（连字符），不是 `docker compose`

### 3.3 参考环境（会话中出现过）

- 控制平台：Ubuntu，`/opt/sip-proxy/gfc-platform`，公网 `103.78.41.16`，Web `5173`，API `8080`
- 测试设备：ImmortalWrt，设备名 ImmortalWrt，**device id=6**，反代端口 **6080/6081**
- 客户端公网 IP 约 `103.153.113.234`（日志中 autossh 来源）

---

## 4. 下一步计划（建议顺序）

### P0 — 让端到端 WebSSH 在测试机跑通

1. **控制平台**（Ubuntu）  
   ```bash
   cd /opt/sip-proxy && git pull   # 至少 4fd9ae1
   cd gfc-platform
   sudo bash deploy/control/setup-reverse-ssh.sh
   docker-compose build api web
   docker rm -f gfc-platform_api_1 gfc-platform_web_1 2>/dev/null
   docker-compose up -d --no-deps api web
   # 或: sudo bash deploy/control/repair-control.sh
   ```
   验证：  
   - `ls -l /data/pki/webssh_id*`（api 容器内或 host 卷）  
   - `curl -fsS http://127.0.0.1:8080/healthz`  
   - `ss -lntp | grep 6080`（隧道建立后）

2. **ImmortalWrt** — 编译安装 **最新 `gfc-agent`**（含 `websshauth.go` + `reversessh` 修复）  
   ```sh
   /etc/init.d/gfc-agent restart
   # 等一次心跳后：
   grep gfc-webssh /etc/dropbear/authorized_keys
   logread | grep -E 'webssh|reverse ssh'
   ```

3. **端到端**  
   - UI 点「远程 SSH」→ 等 15–20s → 应打开 `/client-devices/6/ssh`  
   - 或浏览器直接访问 `http://<CP>:5173/client-devices/6/ssh`  
   - 终端应出现 BusyBox/ImmortalWrt banner，**无** Permission denied

4. **若隧道仍不自动起**  
   - 确认 UI 已建会话（`GET /admin/client-devices/6/reverse-ssh/session` → `tunnel_ready`）  
   - 临时：`/usr/lib/gfc-client/reverse-ssh-run.sh &`（仅调试）  
   - 根因仍是旧 agent → 必须升级 agent

### P1 — 稳定化

- 确认 `gfc-reverse-ssh` procd 开机策略（仅会话 active 时由 agent 管理，符合设计）
- 评估是否在 LuCI/文档中写「远程管理前置条件」：autossh、openssh-keygen、agent 版本
- Web 管理 / 刷码反代：隧道 + `6081` 就绪后测 `/remote/6/luci/...`

### P2 — 产品化（未做）

- 会话 TTL / 审计日志运营化
- 多设备端口池耗尽告警
- 可选：禁止 `chattr +i` 手改 init 的需求（靠新 agent 消除）

---

## 5. 踩过的坑 — 新对话不要再踩

### 5.1 架构 / 协议

| 坑 | 正确理解 |
|----|----------|
| `ssh gfc-reverse@CP true` 报 *This account is currently not available* | `gfc-reverse` 是 **nologin**，不能跑 shell 命令；**autossh -N 端口转发仍可用** |
| 混淆 212 与 211 | **保持 CP sshd = 212**；`GFC_REVERSE_SSH_SSHD_PORT=212` |
| 以为 `reverse ssh :6080 -> ...` 日志 = 隧道已建立 | 旧 agent **restart 成功就打印**，不验证 `pidof autossh` |
| 一条密钥走天下 | **两套密钥**：① 盒子→CP `reverse_ssh_id` → gfc-reverse；② CP→盒子 WebSSH `/data/pki/webssh_id` → root@dropbear |
| WebSSH 连 `8080` | 错；LuCI 在 **:80**，反代 HTTP 用 `P+1` |

### 5.2 ImmortalWrt 客户端

| 坑 | 处理 |
|----|------|
| init 写死 `/usr/bin/autossh` | 实际是 **`/usr/sbin/autossh`**；新代码 `LookPath` + wrapper |
| `-o ServerAliveCountMax=3` | dropbear ssh **不支持**，会 warning；已从生成脚本移除 |
| procd 内联超长 `autossh` 命令难调试 | 用 **`/usr/lib/gfc-client/reverse-ssh-run.sh`** |
| 两个 autossh 抢同一 `-R 6080` | `killall autossh` 后只留 init 拉起的一个 |
| 手改 init 后被 agent 覆盖 | 升级 agent；或临时 `chattr +i`（仅救急） |
| 未点 UI「远程 SSH」就 expect 隧道 | 按需设计：无会话 → agent **`stopUnit`** 停隧道 |

### 5.3 控制平台 Docker / 部署

| 坑 | 处理 |
|----|------|
| `docker-compose up` recreate 报 **`ContainerConfig`** | 先 `docker rm -f gfc-platform_*`，或用 **`gfc-compose` / `repair-control.sh`** |
| 单文件挂载 `.../authorized_keys` 且宿主机无文件 | Docker 会建成 **目录**，API 启动/sync 失败 → 改挂载 **目录** `/var/lib/gfc/reverse-ssh:/data/reverse-ssh` |
| API 在 bridge 网段 probe `127.0.0.1:6080` | 隧道在 **宿主机 loopback**；API 需 **`network_mode: host`** |
| `authorized_keys` 写在容器卷里 | sshd 在 **宿主机**；必须 bind-mount 到 `/var/lib/gfc/reverse-ssh/authorized_keys` |
| `docker compose` vs `docker-compose` | 该环境用 **`docker-compose`** |
| `docker compose down -v` | **会清 SQLite**，设备列表会空 |

### 5.4 Web UI

| 坑 | 处理 |
|----|------|
| `window.open('/#/client-devices/6/ssh')` | 项目用 **BrowserRouter**，`#/` 被忽略 → 落到 **仪表盘**；应用 **`/client-devices/6/ssh`**（`0fb5aa2`） |
| WebSocket 连上显示「已连接」但 SSH 失败 | WS 只表示连上 API；Shell 要另判（`Permission denied` 等） |
| `waitForTunnel` 一直 loading | CP 上无 `6080` LISTEN，或 API 探测失败，或会话过期 |

### 5.5 数据 / 迁移

| 坑 | 处理 |
|----|------|
| 老设备无 `reverse_ssh_port` | 心跳 / 建会话时 **`ensure_device_reverse_ports`**（`cc787fa`） |
| SQLite naive datetime vs aware | `session_active` 须 **`ensure_utc`**，否则列表 API **500**（`caa18ea`） |
| 客户端心跳回写 `reverse_ssh_port` 覆盖 CP | 已 **禁止客户端覆盖** 服务端端口池（`cc787fa`） |

---

## 6. 关键文件索引（新对话从这里读）

```
gfc-platform/
  control-plane/api/app/
    reverse_ssh.py      # 端口池、会话、authorized_keys、gfc-reverse 命令
    webssh_keys.py      # WebSSH 密钥对自动生成 (4fd9ae1)
    webssh.py           # WebSocket → ssh -p P root@127.0.0.1
    clients.py          # 心跳、activate、webssh_authorized_key 下发
    admin.py            # reverse-ssh/session API
    remote_proxy.py     # /remote/{id}/...
  web-ui/src/
    lib/openRemote.ts   # 点按钮 → 建会话 → waitForTunnel → 开 WebSSH
    lib/reverseSsh.ts
    pages/ClientWebSSHPage.tsx
  deploy/control/
    setup-reverse-ssh.sh
    repair-control.sh
    gfc-compose.sh
  docker-compose.yml    # api: network_mode: host; web: host.docker.internal:8080

gfc-client/
  internal/reversessh/
    reversessh.go       # autossh、OpenWrt init/wrapper
    websshauth.go       # dropbear authorized_keys (4fd9ae1)
  internal/agent/runner.go
  internal/controlplane/client.go
```

---

## 7. 架构约束（修改前必读）

仓库 `.cursor/rules/` 强制协议 — **未获用户「确认修改」不得改**：

- `docs/SINGBOX_ARCHITECTURE.md` / sing-box 生成器
- `docs/UNBOUND_ARCHITECTURE.md` / DNS
- `docs/NFT_ARCHITECTURE.md` / nftables

本任务 **数据面 nft/sing-box/unbound 未改**；动的是控制平台 + 客户端 agent 运维通道。

---

## 8. Git 参考（main 上相关提交，由旧到新）

```
cf8b338  feat: reverse SSH sessions + remote access (P0/P1)
e1d5ade  fix: sshd port 212 + nginx /remote
e235acc  ui: line-code button + network rate card
caa18ea  fix: client list 500 (datetime) + curl in API image
cc787fa  fix: port allocation on heartbeat, no client overwrite
40088ed  fix: API host network + reverse-ssh host wiring
56addc8  fix: authorized_keys volume mount (directory)
0fb5aa2  fix: WebSSH URL BrowserRouter not hash
553be72  fix: ImmortalWrt autossh path + wrapper + verify
a754704  fix: ssh probe with -N for nologin gfc-reverse
ec5568e  fix: webssh sshpass fallback (optional)
4fd9ae1  feat: automate WebSSH key via heartbeat  ← 交接时最新
```

---

## 9. 给新对话的一句开场白

> 我们在做 GFC 控制平台对 ImmortalWrt 的 **按需反向 SSH**（端口 6080/6081，sshd 212）。隧道手动已通，代码上 WebSSH 自动密钥在 `4fd9ae1`。请帮用户在 **Ubuntu CP 部署 api+web**、**盒子升级 gfc-agent**，并验证 `grep gfc-webssh /etc/dropbear/authorized_keys` 与 WebSSH 页面无 Permission denied。勿动 nft/sing-box/unbound。部署用 `docker-compose` + `repair-control.sh`，不要 `down -v`。

---

*本文档仅描述会话交接状态；若与 `docs/SINGBOX_ARCHITECTURE.md` 等权威文档冲突，以权威文档为准。*
