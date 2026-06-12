# GFC Client Agent

Ubuntu 22.04 软路由 / ARM 盒子客户端。**独立目录**，离线安装不依赖 `gfc-platform/`。

仓库：https://github.com/278946647/sip-proxy（本目录为 `client-agent/`）

---

## 流程

1. 控制平台创建客户端线路 → 复制 Base32 线路码  
2. 安装完成后刷码：`http://192.168.68.1:81/`（可离线，无需提前配置控制平台）  
3. 联网后 Agent 自动激活 → VLESS+REALITY+Vision → 转发节点  

## 网络（OpenWrt 模式）

- 第一块网卡 = **WAN**（DHCP 获取）
- 其余网卡 = **LAN**（`192.168.68.1/24`，DHCP `192.168.68.100–250`）
- 默认 **网关模式** + BBR

## Web 管理

| 端口 | 说明 |
|------|------|
| **80** | 管理后台（概览 / 设置 / 服务 / 日志） |
| **81** | 刷入线路码 / 平台码（独立页） |

---

## 安装

```bash
cd client-agent
sudo bash deploy/flash-line-code.sh /path/to/linecode.b32
sudo bash deploy/install.sh
```

## 离线 tar（仅含本目录）

```bash
bash deploy/pack-offline.sh
# → dist/gfc-client-offline-x86_64-*.tar.gz
```

详见 [docs/CLIENT_DEPLOY.md](docs/CLIENT_DEPLOY.md)

---

## 代理模式

| 模式 | 环境变量 |
|------|----------|
| 网关 | `GFC_PROXY_MODE=gateway` |
| 旁路 | `GFC_PROXY_MODE=bypass` |
| 透明 | `GFC_PROXY_MODE=transparent` + `GFC_LAN_IFACE=eth1` |

---

## 本地开发

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m client_agent --server http://127.0.0.1:8080 --line-code "..." 
```
