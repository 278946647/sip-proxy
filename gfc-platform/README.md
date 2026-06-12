# Global Forwarding Control Plane (GFC)

控制平台 + 转发节点（**不含客户端运行时**）。客户端见仓库根目录 [`../client-agent/`](../client-agent/)。

**仓库:** https://github.com/278946647/sip-proxy

---

## 本目录结构

| 目录 | 说明 |
|------|------|
| `control-plane/api` | 控制面 API（FastAPI） |
| `web-ui` | Web 管理台 |
| `node-agent` | 转发节点 Agent |
| `deploy/control` | 控制面 Docker 安装 |
| `deploy/node` | 转发节点安装 |
| `deploy/dataplane` | TPROXY / REALITY 数据面说明 |

---

## 快速开局

### 控制平台

```bash
git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform
sudo bash deploy/control/install-docker.sh
```

### 转发节点

```bash
git clone https://github.com/278946647/sip-proxy.git /var/socks-src
cd /var/socks-src/gfc-platform
sudo bash deploy/node/install.sh
```

---

## 文档

| 文档 | 说明 |
|------|------|
| [SETUP_AND_UPGRADE.md](docs/SETUP_AND_UPGRADE.md) | 主文档 |
| [OPS.md](docs/OPS.md) | 运维 |
| [NODE_DEPLOY.md](docs/NODE_DEPLOY.md) | 转发节点 |
| [DEPLOY_FROM_GITHUB.md](docs/DEPLOY_FROM_GITHUB.md) | 验证 checklist |

客户端部署：[../client-agent/docs/CLIENT_DEPLOY.md](../client-agent/docs/CLIENT_DEPLOY.md)

---

## 本地开发

```bash
cd control-plane/api && python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && uvicorn app.main:app --reload --port 8080

cd web-ui && npm install && npm run dev

cd node-agent && pip install -r requirements.txt
python -m node_agent --server http://localhost:8080 \
  --bootstrap-token demo-bootstrap --node-name demo --region ap-southeast-1
```

Docker：`cp .env.example .env && ./gfc-compose up -d`（勿直接用 `docker-compose up` 替换容器，见 `deploy/control/gfc-compose.sh`）
