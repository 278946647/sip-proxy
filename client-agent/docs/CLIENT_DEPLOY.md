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

日志：`/var/log/gfc-client/`（默认 sing-box 仅 `error`；Web「服务管理 → sing-box」可开详细日志。logrotate 保留 1 天 / 50MB）

---

## sing-box 分流与 DNS（验证）

### 未刷码（idle）

- sing-box 无 TUN、无 DNS hijack；mosdns 监听 `127.0.0.1:5335`，上游全部本地 WAN 直连。
- 检查：`jq '.inbounds | length' /etc/gfc-client/sing-box.json` → `0`

### 已刷码（active）

- DNS：国内 UDP 直连（223.5.5.5）；国际 **DoH**（`https://1.1.1.1/dns-query`）走 HTTPS→VLESS，避免 UDP DNS 塞进隧道导致 CPU 爆满。
- 流量：meta-rules-dat 规则集（`geosite-cn` / `geoip-cn` 直连，`geolocation-!cn` 走代理）。
- 规则文件：`/etc/gfc-client/rules/*.srs`；更新：`sudo bash deploy/fetch-meta-rules.sh` 或 Web「更新分流规则集」。

### 测试机验证步骤

```bash
# 1. 同步代码后重装或 repair
cd /opt/gfc-client/client-agent   # 或源码目录
sudo bash deploy/repair-dataplane.sh

# 2. idle：未激活时应无 hijack
jq '.route.rules[] | select(.action=="hijack-dns")' /etc/gfc-client/sing-box.json
# 无输出；inbounds 为空

# 3. 刷码激活后
sudo bash deploy/flash-line-code.sh --file /path/to/line.b32
sleep 15
jq '.route.rules[] | select(.action=="hijack-dns")' /etc/gfc-client/sing-box.json
# 应有 hijack-dns

# 4. 国内 DNS 直连、国际 DNS 不在 direct 列表
jq '.route.rules[] | select(.ip_cidr!=null)' /etc/gfc-client/sing-box.json
# 应含 223.5.5.5/32，不含 8.8.8.8/32

# 5. meta-rules 已加载
jq '.route.rule_set[].tag' /etc/gfc-client/sing-box.json
# geosite-cn geoip-cn geosite-geolocation-!cn

# 6. 日志级别默认 error
jq '.log.level' /etc/gfc-client/sing-box.json
# "error"

# 7. 改 DNS 列表后代理不应掉线
curl -s http://127.0.0.1/api/dns/lists | jq '.lists.china.count'
# 编辑后 apply；gfc0 仍存在： ip link show gfc0

# 8. 分流探测（LAN 客户端）
curl -4 --connect-timeout 5 https://www.baidu.com -I    # 应成功（直连）
curl -4 --connect-timeout 15 https://www.google.com -I  # 代理可用时应成功
```

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
