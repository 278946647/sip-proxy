# GFC Client

ImmortalWrt / Ubuntu 边缘网关客户端：**Go 后端 + LuCI 管理 + Unbound DNS + Sing-box TUN**。

## 架构

- **Unbound** `:53` — LAN DNS，国内/国外分流
- **Sing-box TUN** `gfctun` — kernel-split 国际流量
- **gfc-agent** — 刷码激活、心跳、配置编排
- **gfc-api** `:8080` — **仅 REST API**（LuCI 后端，无独立 Vue 管理页）
- **设备激活** — `http://<设备IP>/gfc/activate.html`（端口 80，无需登录）

控制平台通过 **线路码** 下发节点与控制面地址；数据面配置本地渲染。

## ImmortalWrt 测试机部署

```bash
# Ubuntu 编译机
cd gfc-client
bash deploy/build.sh
GOARCH=arm64 bash deploy/immortalwrt/pack-runtime.sh   # 按设备架构

# 测试机
scp dist/gfc-immortalwrt-runtime-*.tar.gz root@<设备IP>:/tmp/
ssh root@<设备IP> 'cd /tmp && tar xzf gfc-immortalwrt-runtime-*.tar.gz && cd gfc-immortalwrt-runtime-* && ./install.sh'
```

管理界面：`http://<设备IP>/cgi-bin/luci/admin/gfc`

## Ubuntu 安装

```bash
sudo bash deploy/install-ubuntu.sh
sudo bash deploy/verify-install.sh
```

## 目录

| 路径 | 说明 |
|------|------|
| `/usr/lib/gfc-client/` | deploy、share、规则数据 |
| `/etc/gfc-client/` | sing-box、unbound、gfc.env |
| `/var/lib/gfc-client/` | SQLite、状态、备份 |

## API

`http://127.0.0.1:8080/api/v1/*` — 供 LuCI 与脚本调用；浏览器访问根路径将提示使用 LuCI。

## 已废弃

- **MosDNS** / EasyMosDNS 数据面（已移除）
- **独立 Vue3 管理后台**（`gfc-client/web/`，不再构建部署；管理统一走 LuCI）
