# GFC 开局配置与迭代升级手册

适用于 **Global Forwarding Control Plane（GFC）**：控制平台（Docker）+ 转发节点（Ubuntu 裸机）的完整部署、业务配置与在线升级。

| 项目 | 说明 |
|------|------|
| GitHub | https://github.com/278946647/sip-proxy |
| 控制平台默认路径 | `/opt/gfc` |
| 转发节点仓库路径 | `/var/socks`（安装后 Agent 在 `/opt/gfc-node`） |
| Web 端口 | `5173` |
| API 端口 | `8181` |
| 日常跟踪分支 | **`main`**（勿长期 `git checkout` 停在 tag 上升级） |

---

## 1. 架构速览

```
[开发机 Cursor] --git push--> [GitHub]
                                  |
                    +-------------+-------------+
                    |                           |
            [控制平台 VM]                 [转发节点 VM]
            API + Web + DB                sing-box + nft + Agent
                    |                           |
                    +---- 配置下发 / 心跳 -------+
```

- **控制平台宕机**：已下发到节点的 sing-box / 路由 / TPROXY **继续转发**，仅失去控制台管理与配置下发能力（详见 [OPS.md](OPS.md)）。
- **首次安装**：控制平台 API 自动生成 Bootstrap Token、Auth Secret、管理员密码（写入 SQLite），无需手工填 `.env` 密钥。

---

## 2. 开发机（Cursor）同步到 GitHub

在 Windows + Cursor 项目目录执行：

```powershell
cd C:\Users\哈哈\Developer\global-forwarding-control-plane

# 查看变更
git status
git diff

# 暂存并提交
git add .
git commit -m "feat: your change description"

# 推送到 main
git push origin main
```

可选：打版本标签（用于「冻结」某次发布快照，**日常升级请用 `main`**）：

```powershell
git tag -a v0.2.4 -m "release notes"
git push origin v0.2.4
```

**私有仓库**：服务器 clone 时使用 PAT 或 SSH；开发机配置 `git remote -v` 确认 `origin` 指向正确地址。

---

## 3. 控制平台 — 干净开局（Ubuntu 22.04）

### 3.1 一键安装（推荐，交互填写 IP/域名）

```bash
sudo apt update && sudo apt install -y git

sudo git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform
sudo git checkout -B main origin/main

# 交互式：填写控制平台对外地址（IP 或域名）、API 端口、可选备用地址
sudo bash deploy/control/install-docker.sh
```

脚本会自动写入 `.env` 并启动 Docker，**无需手工编辑 docker-compose.yml**。

或一条命令（自动 clone + 交互）：

```bash
sudo bash deploy/control/install-docker.sh \
  --clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy/gfc-platform
```

批量/自动化时使用配置文件：

```bash
cp deploy/control/install.env.example deploy/control/install.env
sudo nano deploy/control/install.env
sudo bash deploy/control/install-docker.sh --config deploy/control/install.env --yes
```

### 3.2 验证

```bash
cd /opt/gfc
curl -fsS http://127.0.0.1:8181/healthz
docker-compose ps
docker-compose logs api 2>&1 | grep "GFC] Security"   # 首次安装可见自动生成的密钥提示
```

浏览器访问：`http://<控制面IP>:5173`

- 用户：`admin`
- 用户名 `admin`，初始密码 **`admin123`**（登录页显示；亦可在 API 日志 `grep 'GFC] Security'` 查看）
- **首次登录须修改密码**（改密前 `generated_admin_password` 保留，流程不变）

### 3.3 平台安全页说明

- Bootstrap Token 默认**锁定只读**（灰色虚线框，非输入框）
- 点击「解锁编辑」→ 修改 →「保存安全设置」需**双重确认**
- 页脚应显示：**安全设置界面 v2**

---

## 4. 转发节点 — 干净开局（Ubuntu 20.04+）

### 4.1 拉取代码

```bash
sudo apt update && sudo apt install -y git

sudo git clone https://github.com/278946647/sip-proxy.git /var/socks-src
cd /var/socks-src/gfc-platform
sudo git checkout -B main origin/main
```

### 4.2 方式 A：交互安装（推荐）

```bash
cd /var/socks
sudo bash deploy/node/install.sh
```

| 参数 | 说明 |
|------|------|
| 控制平台地址 / 端口 | IP 或域名，组成 `SERVER_URL`；可选备用地址 |
| Bootstrap Token | 与控制面「平台安全」中一致 |
| NODE_NAME | 控制台显示名称 |
| TPROXY 网卡 | 客户/VyOS 入向网卡（如 `ens224`） |

### 4.3 方式 B：配置文件（批量）

```bash
cp deploy/node/install.env.example deploy/node/install.env
sudo nano deploy/node/install.env
sudo bash deploy/node/install.sh --config deploy/node/install.env --yes
```

### 4.4 验证

```bash
sudo bash deploy/node/verify-node.sh
ip rule list | grep fwmark          # 必须有: fwmark 0x1 lookup 100
sudo gfc-logs agent -n 30
systemctl status gfc-node-agent gfc-sing-box --no-pager
```

### 4.5 安装产物

| 路径 | 用途 |
|------|------|
| `/etc/gfc-node/gfc.env` | 运行参数；改后 `systemctl restart gfc-node-agent` |
| `/opt/gfc-node` | node-agent 代码与状态 |
| `/etc/gfc-node/sing-box.json` | 数据面配置（Agent 下发后写入） |

---

## 5. Web UI 业务配置（开局后）

1. 登录控制平台（管理员）
2. **代理配置**：添加 SOCKS，点「检测」应显示 `exit_ip=...`
3. **客户线路**：选择节点 + SOCKS + 源 IP 段（如 `10.10.10.0/30`）
4. **回程路由**（以太网模式）：客户网段 → 下一跳 VyOS IP → TPROXY 入向网卡
5. 下联 PC 源 IP 落在线路 CIDR 内，验证上网与 DNS

---

## 6. 已运行系统 — 控制平台升级

> **前提**：服务器在 `main` 分支；数据库卷 `gfc-data` 会保留，无需重装。

### 6.1 全量升级（API + Web）

```bash
cd /opt/gfc
sudo bash deploy/control/upgrade-control.sh
```

脚本会：`git fetch` → 切到 `origin/main` → 无缓存 build api/web → 安全替换容器 → 检查 `/healthz`。

### 6.2 仅升级 Web 前端

```bash
cd /opt/gfc
sudo bash deploy/control/redeploy-web.sh
```

适用于只改 UI、不动 API 的场景；不触碰数据库。

### 6.3 日常 Compose 命令（统一用 gfc-compose）

安装脚本会把 `gfc-compose` 装到 `/usr/local/bin/`。**不要**直接用 `docker-compose up -d` 替换已有容器（1.29 会报 `ContainerConfig`）。

```bash
cd /opt/sip-proxy/gfc-platform   # 或你的 gfc-platform 目录

gfc-compose build --no-cache web   # 或 api web
gfc-compose up -d                  # 全栈安全重启
gfc-compose up -d web              # 仅 Web（不动 API）
gfc-compose ps
gfc-compose logs --tail=50 api

# 或使用 Makefile
make redeploy-web
make upgrade
```

等价脚本：`sudo bash deploy/control/redeploy-web.sh`、`sudo bash deploy/control/upgrade-control.sh`

### 6.4 控制平台换机 / 新装后重连已有转发节点

转发节点侧：

```bash
# 1. 更新控制面地址与 Bootstrap Token（与新平台「平台安全」一致）
sudo nano /etc/gfc-node/gfc.env

# 2. 清除旧注册状态，重新激活
sudo rm -f /opt/gfc-node/node-agent/state/node_state.json
sudo systemctl restart gfc-node-agent
```

控制面 Web UI 中重新创建 SOCKS、线路等业务配置（除非恢复了旧 `gfc.db` 备份）。

---

## 7. 已运行系统 — 转发节点升级

### 7.1 标准升级（推荐）

```bash
cd /var/socks
sudo git fetch origin
sudo git checkout -B main origin/main

# 同步 Agent 代码、依赖、sing-box 单元，并重启服务
sudo python3 deploy/node/repair_forward_node.py
```

### 7.2 仅改连接参数（不重装）

```bash
sudo bash /var/socks/deploy/node/reconfigure-node.sh
# 网卡变更后强制重载：
sudo bash /var/socks/deploy/node/reconfigure-node.sh --force-reapply
```

### 7.3 配置未生效 / 流量异常

```bash
sudo bash /var/socks/deploy/node/force-reapply.sh
sudo bash /var/socks/deploy/node/verify-node.sh
```

### 7.4 Bootstrap Token 已在控制面修改

控制面保存新 Token 后，约 10 秒内 Agent 会同步到 `/etc/gfc-node/gfc.env`；也可手工对齐后重启：

```bash
sudo systemctl restart gfc-node-agent
```

---

## 8. 推荐升级顺序

| 场景 | 顺序 |
|------|------|
| 常规版本迭代 | ① 开发机 push `main` → ② 控制平台 `upgrade-control.sh` → ③ 各转发节点 `git pull` + `repair_forward_node.py` |
| 仅 UI 修复 | 控制平台 `redeploy-web.sh` |
| 仅 API 逻辑 | 控制平台 build api + 替换 `gfc_api_1`（或全量 `upgrade-control.sh`） |
| 仅节点 Agent | 节点 `repair_forward_node.py`（无需动控制面） |

---

## 9. 常见问题

| 现象 | 处理 |
|------|------|
| `git pull`: You are not currently on a branch | `git fetch origin && git checkout -B main origin/main` |
| `KeyError: ContainerConfig` | 改用 `gfc-compose up -d web` 或 `sudo bash deploy/control/repair-control.sh` |
| `redeploy-web.sh` 不存在 | 先 `git checkout -B main origin/main` 再 pull |
| Bootstrap 403 | 节点 `BOOTSTRAP_TOKEN` 与控制面「平台安全」不一致 |
| 平台安全仍是输入框 | 执行 `redeploy-web.sh`，浏览器 Ctrl+Shift+R |
| 节点控制台离线但业务正常 | 控制面不可达或心跳中断；数据面可能仍在转发 |
| DNS 不通 / 无 fwmark | `force-reapply.sh` 或 `repair_forward_node.py` |
| SOCKS 探测 curl skipped | `gfc-compose build --no-cache api && gfc-compose up -d api` |
| 误用 docker-compose 报错 | 一律改用 `gfc-compose`（见 6.3） |

---

## 10. 相关文档

| 文档 | 内容 |
|------|------|
| [README.md](../README.md) | 项目概览与快速入口 |
| [OPS.md](OPS.md) | 运维、日志、故障排查、`gfc-logs` |
| [NODE_DEPLOY.md](NODE_DEPLOY.md) | 转发节点安装细节 |
| [DEPLOY_FROM_GITHUB.md](DEPLOY_FROM_GITHUB.md) | 从 GitHub 验证部署的简版 checklist |
