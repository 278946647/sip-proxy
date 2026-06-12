# GFC 客户端部署

客户端盒子运行 **Ubuntu 22.04**。本目录 `client-agent/` 与 `gfc-platform/` **完全隔离**；离线 tar **不包含**控制面或转发节点代码。

Monorepo 路径：`sip-proxy/client-agent/`

---

## 目录

| 路径 | 说明 |
|------|------|
| `client_agent/` | Python Agent |
| `deploy/` | 安装、离线打包、镜像构建 |
| `docs/` | 本文档 |

---

## 代理模式

| 模式 | 环境变量 |
|------|----------|
| 网关 | `GFC_PROXY_MODE=gateway` |
| 旁路 | `GFC_PROXY_MODE=bypass` |
| 透明 | `GFC_PROXY_MODE=transparent` + `GFC_LAN_IFACE=eth1` |

---

## 在线安装

1. 控制平台创建客户端线路 → 复制 Base32 线路码  
2. 刷入线路码并**交互安装**（无需手工改配置文件）：

```bash
cd client-agent
sudo bash deploy/flash-line-code.sh /path/to/linecode.b32
sudo bash deploy/install.sh
```

安装时会提示：控制平台地址（可留空，优先用线路码内嵌 URL）、备用地址、代理模式、网卡等。

非交互批量：

```bash
cp deploy/install.env.example deploy/install.env
sudo bash deploy/install.sh --config deploy/install.env --yes
```

---

## 离线 tar（x86 / ARM）

在 Linux 构建机：

```bash
cd client-agent
bash deploy/pack-offline.sh
# → dist/gfc-client-offline-x86_64-0.1.0.tar.gz
# → dist/gfc-client-offline-aarch64-0.1.0.tar.gz
```

目标盒子（tar 内已含 sing-box / mosdns，无需公网）：

```bash
tar xzf gfc-client-offline-x86_64-0.1.0.tar.gz
cd gfc-client-offline-x86_64-0.1.0
sudo bash flash-line-code.sh /media/usb/linecode.b32
sudo bash install.sh --config deploy/install.env.example --yes
```

---

## 磁盘镜像 .img

```bash
cd client-agent
sudo bash deploy/build-image.sh --arch x86_64 --size 4G
# → dist/gfc-client-x86_64-0.1.0.img
```

---

## systemd 服务

| 单元 | 说明 |
|------|------|
| `gfc-client-agent` | 激活 / 心跳 / apply |
| `gfc-mosdns` | DNS 分流 |
| `gfc-client-sing-box` | VLESS+REALITY 出站 |
| `gfc-client-web` | 本地 Web 管理 `:8787`（概览 / 刷码 / 设置 / 日志） |

日志：`/var/log/gfc-client/`

---

## 本地 Web 管理

安装后访问 `http://<盒子LAN IP>:8787`：

- **运行概览** — 设备状态、流量、服务健康
- **线路激活** — 浏览器粘贴 Base32 线路码（**无需互联网**，刷入后联网自动激活）
- **网络设置** — 网关/旁路/透明模式、LAN/WAN 网卡
- **服务状态** — 重启 sing-box / mosdns / agent
- **系统日志** — `/var/log/gfc-client/` 日志

也可命令行刷码（VM 无法浏览器粘贴时推荐）：

```bash
# 方式 1：控制平台 API 取码（在能访问控制平台的机器上）
TOKEN="你的JWT"
LINE_ID=1
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "http://控制平台:8080/admin/lines/${LINE_ID}/line-code" | jq -r .line_code_b32 > /tmp/line.b32

# 方式 2：在盒子上刷入文件
sudo bash /opt/gfc-client/client-agent/deploy/flash-line-code.sh --file /tmp/line.b32
# 或源码路径：
sudo bash /opt/sip-proxy-src/client-agent/deploy/flash-line-code.sh --file /tmp/line.b32

# 方式 3：直接写字符串（注意整段一行，无空格换行）
sudo bash deploy/flash-line-code.sh 'BASE32线路码粘贴在这里'

# 方式 4：手工写入后重启 Agent
sudo nano /etc/gfc-client/activation.b32   # 粘贴线路码，保存
sudo systemctl restart gfc-client-agent
```

## 控制面 API（Agent 使用）

- `POST /clients/activate`
- `POST /clients/heartbeat`
- `GET /clients/me/config`

无需 `gfc-platform` 源码；线路码 JSON 或 `install.env` 中配置 `SERVER_URL`。
