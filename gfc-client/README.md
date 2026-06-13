# GFC Client

Ubuntu 22.04 软路由客户端：**Go 后端 + Vue3 管理界面 + MosDNS + Sing-box TUN**。

## 架构

- **MosDNS** `:5335` — DNS 缓存与国内/国外分流
- **Sing-box TUN** `gfctun` — GeoIP/GeoSite 流量分流，VLESS Reality 出站
- **gfc-agent** — 刷码激活、心跳、配置拉取与渲染
- **gfc-api** — REST API + Vue3 Web（`:80` 管理 / `:81` 刷码）

控制平台通过 **线路码** 下发：控制面 URL、节点 IP/端口、VLESS 参数；其余配置本地固定。

## 快速安装（Ubuntu 22.04）

```bash
git clone https://github.com/278946647/sip-proxy.git
cd sip-proxy/gfc-client
sudo bash deploy/install-ubuntu.sh
sudo bash deploy/verify-install.sh
```

刷码：

```bash
sudo bash deploy/flash-line-code.sh --file /path/to/linecode.b32
# 或访问 http://<LAN-IP>:81
```

## 目录

| 路径 | 说明 |
|------|------|
| `/opt/gfc-client/` | 程序与 Web 静态文件 |
| `/etc/gfc-client/` | 配置（sing-box、mosdns、gfc.env） |
| `/var/lib/gfc-client/` | SQLite、规则 `.srs`、状态 |
| `/var/log/gfc-client/` | 日志 |

## API

Base: `http://<ip>/api/v1`

主要端点：`/status` `/activation/flash` `/nodes` `/policy/groups` `/dns/lists` `/rules` `/services` `/logs`

## 开发

```bash
cd gfc-client
bash deploy/build.sh
./bin/gfc-api   # 需设置 GFC_ROOT 指向源码目录
```

## 运维脚本

| 脚本 | 用途 |
|------|------|
| `deploy/pack-offline.sh` | 打离线 tar（含 sing-box / mosdns 二进制） |
| `deploy/apply-network.sh` | WAN/LAN / dnsmasq / nft |
| `deploy/fetch-meta-rules.sh` | 更新分流规则集 |
| `deploy/repair-dataplane.sh` | 重载数据面 |

详见 [docs/CLIENT_DEPLOY.md](docs/CLIENT_DEPLOY.md)
