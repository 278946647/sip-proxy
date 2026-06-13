# GFC Client 部署手册

Ubuntu 22.04 软路由 / ARM 盒子。本目录 `gfc-client/` 与 `gfc-platform/` **完全隔离**；离线 tar **不包含**控制面代码。

---

## 网络模式

- 第一块网卡 = **WAN**（DHCP）
- 其余网卡 = **LAN**（bridge 或直连，`192.168.68.1/24`，DHCP `.100–.250`）
- 默认 **网关模式** + BBR + TUN `gfctun`

---

## 在线安装

```bash
git clone https://github.com/278946647/sip-proxy.git
cd sip-proxy/gfc-client
sudo bash deploy/install-ubuntu.sh
sudo bash deploy/verify-install.sh
```

刷码：

```bash
sudo bash deploy/flash-line-code.sh --file /path/to/linecode.b32
# 或浏览器 http://192.168.68.1:81
```

---

## 离线包

```bash
cd gfc-client
bash deploy/pack-offline.sh
# → dist/gfc-client-offline-x86_64-1.0.0.tar.gz
```

目标机解压后：`sudo bash deploy/install-ubuntu.sh`

---

## Web 管理

| 端口 | 说明 |
|------|------|
| **80** | Vue3 管理后台 |
| **81** | 刷码页 |

API：`http://<IP>/api/v1/`

---

## systemd 单元

| 单元 | 说明 |
|------|------|
| `gfc-client-agent` | 激活 / 心跳 / 配置 apply |
| `gfc-client-api` | REST + Web UI |
| `gfc-mosdns` | DNS 分流 `:5335` |
| `gfc-client-sing-box` | TUN 出站 |

日志：`/var/log/gfc-client/`

---

## 运维脚本

| 脚本 | 用途 |
|------|------|
| `deploy/apply-network.sh` | 重配 WAN/LAN / dnsmasq / nft |
| `deploy/fetch-meta-rules.sh` | 更新 `/var/lib/gfc-client/rules/*.srs` |
| `deploy/fetch-easymosdns-lists.sh` | 更新 EasyMosDNS |
| `deploy/repair-dataplane.sh` | 重载 mosdns + sing-box |
| `deploy/check-egress.sh` | 出口诊断 |

---

## 路径

| 路径 | 内容 |
|------|------|
| `/opt/gfc-client/` | 程序与 Web |
| `/etc/gfc-client/` | sing-box、mosdns、gfc.env |
| `/var/lib/gfc-client/` | SQLite、规则、状态 |
