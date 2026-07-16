# 转发节点部署（Ubuntu 20.04+）

## 一键安装（推荐）

在**全新 Ubuntu 20.04+** 上，将**整个仓库**拷到节点（如 `/var/socks`）。脚本会通过 `apt` 安装 Python、nftables、openvpn、rsync 等，无需事先手工装依赖。

### 方式 A：交互式（安装时输入参数）

```bash
cd /var/socks
sudo bash deploy/node/install.sh
```

按提示填写：

| 参数 | 说明 |
|------|------|
| 控制平台地址 / 端口 | IP 或域名，组成 `SERVER_URL`；可选 `SERVER_URL_FALLBACK` 备用 |
| Bootstrap Token | 须与控制平台 `GFC_BOOTSTRAP_TOKENS` 一致 |
| NODE_NAME | 控制台显示的节点名 |
| GFC_TPROXY_IFACE | **以太网模式**下 VyOS/骨干入向网卡（如 `ens224`） |

**日后改 OpenVPN 会影响开局网卡吗？** 不会。开局填的物理网卡仅用于以太网直通。控制台切到 OpenVPN 后，会下发 `tproxyIface`（通常 `tun0`），Agent **优先使用下发值**，一般不必改 `gfc.env`。

### 方式 B：配置文件（批量/自动化）

```bash
cp deploy/node/install.env.example deploy/node/install.env
# 编辑 install.env
sudo bash deploy/node/install.sh --config deploy/node/install.env
```

### 方式 C：拷贝后引导

```bash
sudo bash deploy/node/setup-after-copy.sh
```

首次会生成 `deploy/node/install.env` 模板；编辑后执行 `install.sh`。

### 安装产物

| 路径 | 用途 |
|------|------|
| `/etc/gfc-node/gfc.env` | 运行参数，改后 `systemctl restart gfc-node-agent` |
| `/etc/gfc-node/install.env` | 安装参数备份 |
| `/opt/gfc-node` | node-agent 与状态目录 |

改已装节点（不重装）：

```bash
sudo bash deploy/node/reconfigure-node.sh
# 网卡变更后强制重载 nftables/sing-box：
sudo bash deploy/node/reconfigure-node.sh --force-reapply
```

控制平面侧可先检查：

```bash
./scripts/check-prereq.sh
API=http://<控制平台IP>:8181 ./scripts/verify-loop.sh
```

## 兼容：环境变量

```bash
sudo SERVER_URL=http://<IP>:8181 NODE_NAME=MY-Node-01 GFC_TPROXY_IFACE=ens224 \
  bash deploy/node/install.sh --yes
```

## 功能说明

| 需求 | 实现 |
|------|------|
| 节点名称调整 | 控制台「转发节点」改名；Agent 心跳携带 `node_name` 同步 |
| 主动激活 | 首次启动 `POST /nodes/activate`，token 存本地 state |
| 监控检测 | 心跳上报 systemd 服务状态（sing-box、openvpn-backbone）、控制面可达性 |
| 服务日志 | `/var/log/gfc-node/*.log`，约 1 天 logrotate；查询：`gfc-logs agent -f` |
| 配置下发 | 拉取配置哈希版本，变更时渲染 sing-box + nftables + OpenVPN 并 ack |
| OpenVPN 骨干 | 控制台配置证书；`connect_mode=openvpn` 时 Agent 写 `/etc/openvpn/gfc-backbone/` |

## 手工调试（前台日志）

```bash
cd /var/socks
cp deploy/node/install.env.example deploy/node/install.env   # 编辑 SERVER_URL 等
bash deploy/node/run-manual-debug.sh
```

## 已安装但异常

```bash
sudo python3 /var/socks/deploy/node/repair_forward_node.py
```

或：

```bash
set -a && source /etc/gfc-node/gfc.env && set +a
export REPO_SRC=/var/socks
sudo -E bash /var/socks/deploy/node/repair-install.sh
```

排查激活失败：

```bash
journalctl -u gfc-node-agent -n 50 --no-pager
curl -fsS "$(grep SERVER_URL /etc/gfc-node/gfc.env | cut -d= -f2-)/healthz"
systemctl cat gfc-node-agent   # ExecStart 应为 /usr/local/bin/gfc-node-agent-start
```

### 公网 IP（GCP / 云 NAT）

Agent ≥ `0.3.1` 会探测真正可从公网访问的 IPv4（HTTP egress / GCP metadata），并拒绝上报 RFC1918。  
若控制台「公网 IP」仍为 `10.x`/`172.x`，升级 Agent 后重启：

```bash
systemctl restart gfc-node-agent
journalctl -u gfc-node-agent -n 30 --no-pager | grep -i public
```

仍失败时可在 `/etc/gfc-node/gfc.env` 钉死：

```bash
GFC_NODE_PUBLIC_IP=你的GCP外部IP
systemctl restart gfc-node-agent
```

注意：VM 必须绑定 **External IP**（或等价 inbound 可达地址）；仅 Cloud NAT 共享出口 IP 无法作为 VLESS 入口。

## 服务管理

```bash
systemctl status gfc-node-agent gfc-sing-box
journalctl -u gfc-node-agent -f
```

## VyOS 侧

OpenVPN **site-to-site** 需在 VyOS 手工配置对端（隧道地址、路由、证书）。控制平台仅下发**转发节点客户端**配置。
