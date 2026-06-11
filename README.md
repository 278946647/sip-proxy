# sip-proxy

SOCKS / 应用加速管控平台 monorepo：**控制面 + 转发节点** 与 **客户端盒子** 分目录隔离；客户端离线安装不依赖平台代码。

**GitHub:** https://github.com/278946647/sip-proxy

---

## 仓库结构

```
sip-proxy/
├── gfc-platform/          # 控制平台 + 转发节点（服务器侧）
│   ├── control-plane/     # FastAPI 控制面 API
│   ├── web-ui/            # Web 管理台
│   ├── node-agent/        # 转发节点 Agent
│   ├── deploy/control/    # 控制面 Docker 安装
│   ├── deploy/node/       # 转发节点安装
│   └── docker-compose.yml
│
└── client-agent/          # 客户端盒子（独立交付，可单独打包）
    ├── client_agent/      # Python Agent
    └── deploy/            # 安装 / 离线 tar / 镜像构建
```

| 组件 | 目录 | 部署目标 |
|------|------|----------|
| 控制平台 | `gfc-platform/` | Ubuntu + Docker，路径如 `/opt/gfc` |
| 转发节点 | `gfc-platform/node-agent` | Ubuntu 裸机，路径如 `/var/socks` |
| 客户端盒子 | `client-agent/` | Ubuntu 22.04 软路由，路径 `/opt/gfc-client` |

---

## 快速开始

### 1. 控制平台

```bash
git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform
sudo bash deploy/control/install-docker.sh
```

- Web：`http://<IP>:5173`　API：`http://<IP>:8080`

### 2. 转发节点

```bash
git clone https://github.com/278946647/sip-proxy.git /var/socks-src
cd /var/socks-src/gfc-platform
sudo bash deploy/node/install.sh
```

### 3. 客户端盒子（仅需 client-agent）

```bash
# 从 monorepo
cd client-agent
sudo bash deploy/flash-line-code.sh /path/to/linecode.b32
sudo bash deploy/install.sh --config deploy/install.env.example --yes

# 或打离线包（不含 gfc-platform）
bash deploy/pack-offline.sh
```

---

## 文档

| 文档 | 说明 |
|------|------|
| [gfc-platform 平台手册](gfc-platform/docs/SETUP_AND_UPGRADE.md) | 控制面 / 转发节点开局与升级 |
| [client-agent 部署](client-agent/docs/CLIENT_DEPLOY.md) | 离线 tar、镜像、三种代理模式 |
| [首次推送 GitHub](docs/GITHUB_FIRST_PUSH.md) | Git 初始化与 push |

---

## 设计原则

- **Monorepo 开发、分目录交付**：Git 一个仓库；客户端 `pack-offline.sh` 只打包 `client-agent/`。
- **控制面与数据面分离**：平台故障时，已下发配置仍在节点/客户端本地生效。
- **客户端直连转发节点**：VLESS + REALITY + Vision；每客户端独立 UUID，节点共用 REALITY 配置。
