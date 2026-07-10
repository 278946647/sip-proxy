# GFC — Global Forwarding Control

企业级跨境网络边缘网关与管控平台 monorepo。控制面、转发节点、客户端网关分目录开发与交付；客户端可独立打包离线安装，不依赖平台代码。

**仓库：** https://github.com/278946647/sip-proxy  
**当前交付：** 控制平台 + 网关模式（`kernel-split`）数据面

---

## 产品形态

| 组件 | 目录 | 部署目标 | 技术栈 |
|------|------|----------|--------|
| **控制平台** | `gfc-platform/` | Ubuntu 20.04+，Docker | FastAPI · Vue3 Web UI · SQLite |
| **转发节点** | `gfc-platform/node-agent` | Ubuntu 裸机 | sing-box TPROXY · VLESS Reality · nftables |
| **客户端网关** | `gfc-client/` | ImmortalWrt / Ubuntu 22.04 | Go · LuCI · Unbound · sing-box TUN |

```
                    ┌─────────────────────────────────┐
                    │     控制平台 (gfc-platform)      │
                    │  Web :5173  │  API :8080        │
                    │  线路管理 · 节点编排 · 远程运维    │
                    └──────────┬──────────────────────┘
                               │ 配置下发 / 心跳
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
     ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
     │  转发节点 VM    │ │  转发节点 VM  │ │  客户端网关盒子    │
     │  TPROXY 入向    │ │  ...         │ │  ImmortalWrt /    │
     │  SOCKS → 出境   │ │              │ │  Ubuntu 软路由     │
     └────────┬───────┘ └──────┬───────┘ └────────┬─────────┘
              │                │                   │
              └────────────────┴──── VLESS Reality ─┘
```

**控制面与数据面分离：** 平台宕机后，已下发到节点/客户端的 sing-box、nft、路由策略继续工作，仅失去集中管理与配置推送能力。

---

## 仓库结构

```
sip-proxy/
├── docs/                      # 数据面权威架构（NFT / Unbound / Sing-box）
├── gfc-platform/              # 控制平台 + 转发节点（服务器侧）
│   ├── control-plane/api/     # FastAPI 控制面 API
│   ├── web-ui/                # Web 管理台（Vue3）
│   ├── node-agent/            # 转发节点 Agent
│   ├── deploy/control/        # 控制面 Docker 一键安装
│   ├── deploy/node/           # 转发节点一键安装
│   └── docker-compose.yml
│
└── gfc-client/                # 客户端边缘网关
    ├── cmd/                   # gfc-api · gfc-agent · gfc-bootstrap
    ├── internal/              # 配置渲染、网络 apply、控制面通信
    ├── deploy/                # 安装脚本 · 离线包 · ImmortalWrt 适配
    ├── deploy/immortalwrt/    # LuCI 应用 · runtime 打包 · 验收脚本
    └── share/                 # unbound 模板 · nft 规则数据 · geo 规则
```

---

## 网关模式数据面（客户端）

默认方案 **`GFC_ROUTING_SCHEME=kernel-split`**，经 `v0.3.0` 生产验证：

| 层级 | 组件 | 职责 |
|------|------|------|
| DNS | **Unbound** `:53` | LAN 唯一 DNS；国内域名/IP 走阿里 DNS；国际 DNS 走代理路径 |
| 分流 | **nftables** `inet gfc` | `TO_CN` 直连 WAN · `bypass_ip` 白名单 · `ext` 动态集 |
| 代理 | **sing-box TUN** `gfctun` | 国际流量经 VLESS + Reality 至转发节点 |
| 管理 | **LuCI** + **gfc-api** | 设备本地 REST API；激活门户 `http://<IP>/gfc/activate.html` |
| 编排 | **gfc-agent** | 刷码激活 · 心跳 · 配置拉取与本地渲染 |

```
LAN 终端
  ↓ :53
Unbound（国内/国外 DNS 分流）
  ↓
nft 分类（TO_CN → WAN 直连；其余 → mark 0x2023）
  ↓
策略路由 table 2022 → gfctun → sing-box → VLESS Reality → 转发节点
```

权威规范见 [`docs/NFT_ARCHITECTURE.md`](docs/NFT_ARCHITECTURE.md)、[`docs/UNBOUND_ARCHITECTURE.md`](docs/UNBOUND_ARCHITECTURE.md)、[`docs/SINGBOX_ARCHITECTURE.md`](docs/SINGBOX_ARCHITECTURE.md)。

> **已废弃：** MosDNS / EasyMosDNS 数据面；客户端独立 Vue3 管理后台（`gfc-client/web/`，管理统一走 LuCI）。

---

## 快速部署

按顺序：**控制平台 → 转发节点 → 客户端网关**。

### 1. 控制平台

```bash
sudo apt update && sudo apt install -y git
sudo git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform
sudo bash deploy/control/install-docker.sh
```

- Web 管理台：`http://<IP>:5173`（用户 `admin`，初始密码 `admin123`，首次登录须改密）
- API：`http://<IP>:8080/healthz`
- Bootstrap Token：安装后 `docker compose logs api 2>&1 | grep 'GFC] Security'`

非交互安装：`cp deploy/control/install.env.example deploy/control/install.env` → 编辑 → `sudo bash deploy/control/install-docker.sh --config deploy/control/install.env --yes`

### 2. 转发节点

```bash
sudo git clone https://github.com/278946647/sip-proxy.git /var/socks-src
cd /var/socks-src/gfc-platform
sudo bash deploy/node/install.sh
```

交互填写控制平台地址、Bootstrap Token、节点名称、TPROXY 入向网卡。验证：`sudo bash deploy/node/verify-node.sh`

### 3. 客户端网关

**ImmortalWrt（推荐生产路径）**

```bash
# 编译机
cd gfc-client
bash deploy/build.sh
GOARCH=arm64 bash deploy/immortalwrt/pack-runtime.sh   # 按设备架构选择

# 设备
tar xzf gfc-immortalwrt-runtime-*.tar.gz && cd gfc-immortalwrt-runtime-* && ./install.sh
```

管理界面：`http://<设备IP>/cgi-bin/luci/admin/gfc`  
激活刷码：`http://<设备IP>/gfc/activate.html`

**Ubuntu 22.04 软路由**

```bash
git clone https://github.com/278946647/sip-proxy.git
cd sip-proxy/gfc-client
sudo bash deploy/install-ubuntu.sh
# 用 WAN IP 重连 SSH 后
sudo bash deploy/finish-network-install.sh
sudo bash deploy/flash-line-code.sh --file /path/to/linecode.b32
```

> `install-ubuntu.sh` 不当场 `netplan apply`（避免 LAN bridge 化时 SSH 断线）。需 Go 1.22+（脚本可从 go.dev 自动安装）。

### 4. 业务配置（控制平台 Web UI）

1. **代理配置** — 添加 SOCKS 出口并检测
2. **客户线路** — 绑定转发节点 + SOCKS + 源 IP 段
3. **客户端设备** — 生成线路码，在网关刷码激活
4. （可选）**远程 SSH / LuCI** — NAT 后设备按需反向隧道

---

## 环境要求

| 组件 | 操作系统 | 关键依赖 | 端口 |
|------|----------|----------|------|
| 控制平台 | Ubuntu 20.04+ | Docker · docker-compose · git | 8080 · 5173 |
| 转发节点 | Ubuntu 20.04+ | Python 3 · nftables · sing-box | 12345 TPROXY · 8443 VLESS |
| 客户端 ImmortalWrt | ImmortalWrt / OpenWrt | sing-box（需另行安装）· unbound · opkg | 53 · 80 · 8080 |
| 客户端 Ubuntu | Ubuntu 22.04 x86_64/aarch64 | nftables · unbound · dnsmasq · Go 1.22+ | 同上 |

**网络前提：** 安装脚本需访问 GitHub（clone / sing-box 下载）、Docker Hub（控制面镜像构建）、go.dev（Ubuntu 客户端编译）。纯内网环境需预先镜像或离线包，见下方说明。

---

## 文档索引

### 部署与运维

| 文档 | 说明 |
|------|------|
| [平台开局与升级](gfc-platform/docs/SETUP_AND_UPGRADE.md) | 控制面 / 转发节点主手册 |
| [转发节点部署](gfc-platform/docs/NODE_DEPLOY.md) | 节点安装细节 |
| [运维手册](gfc-platform/docs/OPS.md) | 日志、修复、故障排查 |
| [远程访问](gfc-platform/docs/REMOTE_ACCESS.md) | 反向 SSH · WebSSH · LuCI 反代 |
| [客户端部署](gfc-client/docs/CLIENT_DEPLOY.md) | Ubuntu 安装 · 离线包 |
| [ImmortalWrt 部署](gfc-client/deploy/immortalwrt/README.md) | runtime 打包 · LuCI · 验收 |
| [网关核心](gfc-client/docs/GATEWAY_CORE.md) | kernel-split 数据流说明 |
| [网络 Apply 规范](gfc-client/docs/NETWORK_APPLY.md) | WAN 配置安全 apply / 回滚 |

### 数据面架构（修改前必读）

| 文档 | 说明 |
|------|------|
| [NFT 架构](docs/NFT_ARCHITECTURE.md) | nftables 表/链/mark — 唯一真相 |
| [Unbound 架构](docs/UNBOUND_ARCHITECTURE.md) | LAN DNS 分流规范 |
| [Sing-box 架构](docs/SINGBOX_ARCHITECTURE.md) | kernel-split / 转发节点契约 |

---

## 设计原则

- **Monorepo 开发、分目录交付** — 一个 Git 仓库；客户端 `deploy/pack-offline.sh` / `deploy/immortalwrt/pack-runtime.sh` 独立打包。
- **控制面与数据面分离** — 配置本地渲染；平台故障不影响已激活网关转发。
- **客户端直连转发节点** — VLESS + Reality + Vision；每客户端独立 UUID。
- **中外分流在内核** — nft `TO_CN` + Unbound DNS 分流；sing-box 不做 geo rule_set 中外分流。
- **接口动态发现** — 不硬编码 `eth0` / `192.168.1.0/24`；运行时读取 UCI / netlink。

---

## 本地开发

```bash
# 控制平台（三进程）
cd gfc-platform/scripts && bash start-all.sh

# 控制平台 API 单独
cd gfc-platform/control-plane/api
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && uvicorn app.main:app --reload --port 8080

# Web UI
cd gfc-platform/web-ui && npm install && npm run dev

# 客户端 Go 编译
cd gfc-client && bash deploy/build.sh
```

Docker 方式：`cd gfc-platform && cp .env.example .env && ./deploy/control/gfc-compose.sh up -d`（勿直接用 `docker-compose up` 替换运行中容器）。

---

## 版本与里程碑

| Tag | 说明 |
|-----|------|
| `v1.0.0` | 平台 + 网关模式（kernel-split）功能实现交付 |
| `v0.3.0` | 数据面 kernel-split 生产验证基线 |
| `gfc-remote-ssh-web-v1.0.0` | 远程 SSH / WebSSH / LuCI 反代里程碑 |

---

## 许可证

企业内部项目。部署与二次开发请遵循 `docs/*_ARCHITECTURE.md` 中的变更协议；未经评审不得修改 nft / unbound / sing-box 数据面契约。
