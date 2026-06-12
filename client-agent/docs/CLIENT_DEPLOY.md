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
| `gfc-client-web` | 本地 Web `:8787` |

日志：`/var/log/gfc-client/`

---

## API（仅需控制面 URL）

- `POST /clients/activate`
- `POST /clients/heartbeat`
- `GET /clients/me/config`

无需 `gfc-platform` 源码；线路码 JSON 或 `install.env` 中配置 `SERVER_URL`。
