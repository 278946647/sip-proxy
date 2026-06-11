# GFC 运维手册

本文档面向生产环境日常运维与故障排查，涵盖架构逻辑、日志保留、排查流程与常用命令。

---

## 1. 系统架构概览

```
                    ┌─────────────────────────────────┐
                    │     控制平台 (Control Plane)      │
                    │  Web UI :5173  +  API :8080      │
                    │  SQLite (gfc.db)                 │
                    │  节点注册 / 配置下发 / 告警 / SOCKS 探测 │
                    └───────────────┬─────────────────┘
                                    │ HTTPS/HTTP
                    ┌───────────────▼─────────────────┐
                    │     转发节点 (Forward Node)       │
                    │  gfc-node-agent  (心跳/拉配置)    │
                    │  gfc-sing-box    (TPROXY :12345)  │
                    │  openvpn@gfc-backbone (可选)      │
                    │  nft table inet gfc (TPROXY 劫持) │
                    └───────────────┬─────────────────┘
                                    │ SOCKS5
                                    ▼
                              上游 SOCKS 供应商
```

### 1.1 控制平台职责

| 组件 | 说明 |
|------|------|
| **API** | 节点激活、心跳、配置 bundle、管理后台、SOCKS 健康探测、邮件告警 |
| **Web UI** | 仪表盘、线路/节点/代理管理、用户与 SMTP 设置 |
| **数据库** | 节点、线路、SOCKS、告警、操作日志等（默认 `/data/gfc.db` 或本地 `gfc.db`） |

### 1.2 转发节点职责

| 组件 | 说明 |
|------|------|
| **gfc-node-agent** | 每 ~10s 心跳；配置变更时渲染 sing-box、nft、路由、OpenVPN |
| **gfc-sing-box** | 透明代理入口，按源 IP 匹配线路，转发到对应 SOCKS |
| **nft (table gfc)** | 从 `GFC_TPROXY_IFACE`（或 OpenVPN 的 `tun0`）劫持 TCP/UDP 到 12345 |
| **openvpn@gfc-backbone** | 与 VyOS 骨干建立隧道（可选） |

### 1.3 一条流量的路径

1. VyOS 将客户网段流量送到转发节点入向网卡（或 tun0）
2. nft TPROXY → sing-box :12345
3. sing-box 按源 IP 最长前缀匹配线路 → 对应 SOCKS outbound
4. 应答经 conntrack + 策略路由 + **回程静态路由** 回到 VyOS

---

## 2. 日志保留策略

目标：**至少保留约 1 天**的关键服务日志，同时限制磁盘占用。

### 2.1 控制平台（systemd / start-all.sh）

| 日志文件 | 服务 |
|----------|------|
| `/var/socks/logs/gfc-api.log` | API |
| `/var/socks/logs/gfc-web.log` | Web UI |
| `/var/socks/logs/gfc-node.log` | 同机 Node Agent（如有） |

**轮转规则**（`/etc/logrotate.d/gfc-control-plane`）：

- 按天轮转，保留 1 份归档（`rotate 1` + `maxage 1`）
- 单文件超过 **50MB** 提前轮转（`size 50M`）
- 压缩旧日志（`compress`）

安装/更新：

```bash
sudo bash deploy/scripts/install-logrotate.sh control /var/socks/logs
# 或通过 systemd 安装脚本自动执行：
sudo bash deploy/systemd/install-systemd.sh
```

### 2.2 转发节点

| 日志文件 | 服务 |
|----------|------|
| `/var/log/gfc-node/gfc-node-agent.log` | Node Agent |
| `/var/log/gfc-node/sing-box.log` | sing-box |
| `/var/log/gfc-node/openvpn-gfc-backbone.log` | OpenVPN 客户端 |

**轮转规则**：`/etc/logrotate.d/gfc-forward-node`（同上，目录为 `/var/log/gfc-node`）

**journald 兜底**（`/etc/systemd/journald.conf.d/gfc-forward-node.conf`）：

- `MaxRetentionSec=1day`
- `SystemMaxUse=300M`

新装节点由 `install-ubuntu.sh` 自动配置。已部署节点可执行：

```bash
# 在节点上（仓库路径下）
sudo bash deploy/scripts/install-logrotate.sh forward
sudo install -m 755 deploy/scripts/gfc-logs.sh /usr/local/bin/gfc-logs

# 为已有 systemd 单元追加文件日志（需与 install-ubuntu.sh 中 unit 一致后 daemon-reload + restart）
sudo systemctl restart gfc-node-agent gfc-sing-box
```

### 2.3 Docker Compose

`web` 服务为 **Vite 生产构建 + nginx**（对外仍映射 `5173` → 容器 `80`），`/api` 由 nginx 反代到 `api:8080`。

`docker-compose.yml` 中 `api` / `web` 使用 `json-file` 驱动：

- API：单文件最大 50MB，最多 3 个文件
- Web：单文件最大 20MB，最多 3 个文件

查看：

```bash
docker compose logs api --tail 200
docker compose logs web --tail 100
```

### 2.4 统一日志查询工具

```bash
sudo gfc-logs agent -n 200          # 转发节点 Agent
sudo gfc-logs sing-box -f           # 跟踪 sing-box
sudo gfc-logs openvpn -g error      # OpenVPN 含 error
sudo gfc-logs api -n 100            # 控制面 API
sudo gfc-logs all-fn                # 转发节点全部文件日志
```

---

## 3. 日常巡检清单

| 检查项 | 命令 / 位置 |
|--------|-------------|
| 控制面 API | `curl -fsS http://<CP>:8080/healthz` |
| 仪表盘 | 节点在线数、SOCKS 在线数、告警数 |
| 转发节点服务 | `systemctl is-active gfc-node-agent gfc-sing-box` |
| OpenVPN（如启用） | `systemctl is-active openvpn@gfc-backbone` |
| TPROXY 规则 | `sudo nft list table inet gfc`（应仅少量 tcp/udp 规则） |
| sing-box 监听 | `ss -ulnp \| grep 12345` |
| 磁盘空间 | `df -h`；`du -sh /var/log/gfc-node /var/socks/logs` |
| 日志轮转 | `ls -lh /var/log/gfc-node/`、`cat /etc/logrotate.d/gfc-forward-node` |

---

## 4. 故障排查流程

### 4.1 节点显示离线

```mermaid
flowchart TD
  A[控制台节点离线] --> B{API 可达?}
  B -->|否| C[查控制面 API 日志 / 防火墙]
  B -->|是| D{节点 gfc-node-agent active?}
  D -->|否| E[gfc-logs agent / systemctl status]
  D -->|是| F{心跳 401? token 失效}
  F -->|是| G[重新激活或修复 state]
  F -->|否| H[查 SERVER_URL / 网络 / 时间同步]
```

**命令：**

```bash
# 转发节点
systemctl status gfc-node-agent --no-pager
gfc-logs agent -n 100
curl -fsS http://<控制面IP>:8080/healthz

# 控制面
gfc-logs api -n 100 | tail -50
```

**常见原因：** 控制面地址错误、防火墙、Agent 未启动、`node_state.json` 损坏、时钟偏差过大。

---

### 4.2 SOCKS 代理显示离线

1. 控制台 → 代理配置 → **检测**
2. 节点上手工验证：

```bash
sudo bash deploy/node/test-socks.sh
# 或
curl -fsS --connect-timeout 12 -x socks5://user:pass@host:port https://api.ipify.org
```

3. 查看控制面 monitor 日志（API 日志中的 SOCKS 探测失败）

**常见原因：** 账号过期、供应商封 IP、密码错误、控制面无法访问外网做 curl 探测。

---

### 4.3 流量不通 / 客户无法上网

按顺序检查：

```bash
# 1. sing-box 配置是否合法
sing-box check -c /etc/gfc-node/sing-box.json

# 2. TPROXY 规则与重复项
sudo nft list table inet gfc
# 若规则重复过多：
sudo nft delete table inet gfc
sudo systemctl restart gfc-node-agent

# 3. 策略路由
ip rule show | grep 0x1
ip route show table 100

# 4. 回程路由（控制台「回程路由」）
ip route | grep <客户网段>

# 5. sing-box 实时日志
gfc-logs sing-box -f
```

**常见原因：** `GFC_TPROXY_IFACE` 错误、无回程路由、SOCKS 失效、线路 source_cidrs 不匹配。

---

### 4.4 OpenVPN 隧道异常

```bash
systemctl status openvpn@gfc-backbone
gfc-logs openvpn -n 100
ip addr show tun0
ping -c 3 <VyOS隧道对端IP>
```

控制台确认节点为 **OpenVPN 模式** 且证书/Static Key 已下发。

---

### 4.5 配置下发失败告警

```bash
gfc-logs agent -n 200 | grep -i fail
# 查看 apply 详情（Agent 会 ack failed 到控制面）
```

常见：`sing-box check` 失败、nft 语法错误、网卡不存在。

---

### 4.6 磁盘空间不足

```bash
df -h
du -sh /var/log/gfc-node/* /var/socks/logs/*
journalctl --disk-usage
```

处理：

```bash
# 手动触发 logrotate
sudo logrotate -f /etc/logrotate.d/gfc-forward-node
sudo logrotate -f /etc/logrotate.d/gfc-control-plane

# 清理已压缩旧日志（logrotate 通常已处理）
sudo journalctl --vacuum-time=1d
```

---

## 5. 常用命令速查

### 5.1 控制平台

```bash
# systemd
systemctl status gfc-api gfc-web
systemctl restart gfc-api

# Docker
docker compose ps
docker compose logs api -f --tail 100

# 数据库（Docker 卷内）
docker compose exec api sqlite3 /data/gfc.db "SELECT COUNT(*) FROM alert_events;"
docker compose exec api sqlite3 /data/gfc.db "DELETE FROM alert_events;"  # 清空历史告警
```

### 5.2 转发节点

```bash
systemctl restart gfc-node-agent
systemctl restart gfc-sing-box
systemctl restart openvpn@gfc-backbone

# 强制重新拉配置
sudo bash deploy/node/force-reapply.sh

# 验证安装
sudo bash deploy/node/verify-node.sh

# 修复安装
sudo bash deploy/node/repair-forward-node.sh
```

### 5.3 网络诊断

```bash
nft list table inet gfc
ss -ulnp | grep -E '12345|sing-box'
ip route
ip rule
sysctl net.ipv4.ip_forward
```

---

## 6. 控制台功能与后台逻辑

| 功能 | 后台逻辑 |
|------|----------|
| 节点在线 | `last_seen_at` 2 分钟内有心跳 |
| SOCKS 在线 | 后台 curl 探测 `api.ipify.org`（约 60s） |
| 节点服务告警 | 心跳 metrics 中 sing-box / openvpn 非 active |
| 节点离线邮件 | monitor 检测在线→离线转换 |
| 告警去重 | 同类告警 30 分钟内不重复 |
| 配置版本 | payload 哈希；变更后节点 apply 并 ack |

---

## 7. 升级与备份建议

| 对象 | 建议 |
|------|------|
| `gfc.db` | 定期备份控制面数据库（含节点 token 哈希、线路、SOCKS） |
| `/etc/gfc-node/gfc.env` | 备份节点环境 |
| `node_state.json` | 备份激活状态（含 node_token） |
| PKI 目录 | 备份 `data/pki`（OpenVPN 证书） |
| 代码升级 | 先控制面 API+Web，再各转发节点 `repair-forward-node.sh` 或重启 agent |

---

## 8. 相关文档

- [NODE_DEPLOY.md](NODE_DEPLOY.md) — 转发节点安装
- [NEXT_STEPS.md](NEXT_STEPS.md) — 部署后验证
- [deploy/dataplane/README.md](../deploy/dataplane/README.md) — 数据面 TPROXY / 路由说明
- [README.md](../README.md) — 项目总览与启动方式

---

## 9. 已有环境启用日志（快速步骤）

**控制平台（已用 systemd）：**

```bash
cd /var/socks   # 或你的 GFC_ROOT
sudo bash deploy/scripts/install-logrotate.sh control /var/socks/logs
sudo install -m 755 deploy/scripts/gfc-logs.sh /usr/local/bin/gfc-logs
```

**转发节点（已安装但未写文件日志）：**

```bash
cd /opt/gfc-node   # 或 REPO 路径
sudo bash deploy/node/install-ubuntu.sh   # 仅更新 unit 时也可手工合并 unit 片段
# 或仅日志：
sudo bash deploy/scripts/install-logrotate.sh forward
sudo systemctl daemon-reload
sudo systemctl restart gfc-node-agent gfc-sing-box openvpn@gfc-backbone
```
