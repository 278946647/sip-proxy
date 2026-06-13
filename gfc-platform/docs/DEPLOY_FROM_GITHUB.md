# 从 GitHub 部署（gfc-platform）

仓库：https://github.com/278946647/sip-proxy（平台代码在 **`gfc-platform/`** 子目录）

## 控制平台

```bash
sudo git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform
sudo bash deploy/control/install-docker.sh
```

## 转发节点

```bash
sudo git clone https://github.com/278946647/sip-proxy.git /var/socks-src
cd /var/socks-src/gfc-platform
sudo bash deploy/node/install.sh
```

## 客户端

见仓库 [`gfc-client/docs/CLIENT_DEPLOY.md`](../gfc-client/docs/CLIENT_DEPLOY.md)（无需克隆整个 monorepo 到盒子，可用离线 tar）。
