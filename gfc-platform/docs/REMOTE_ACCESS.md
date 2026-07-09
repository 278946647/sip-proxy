# GFC 客户端远程接入（反向 SSH / WebSSH / LuCI 反代）

本文档描述控制平台与 ImmortalWrt 客户端之间的远程运维通道，对应 tag `gfc-remote-ssh-web-v1.0.0` 及 P2 加固项。

---

## 1. 架构概览

```
管理员浏览器
    │  Web UI :5173（弹窗）
    ▼
控制面 API :8080
    │  POST /admin/client-devices/{id}/reverse-ssh/session
    │  WebSocket /admin/ws/webssh/{id}
    │  HTTP    /remote/{id}/cgi-bin/luci/...
    ▼
控制面本机 127.0.0.1:{ssh_port} / {http_port}
    ▲  autossh 反向隧道
    │
ImmortalWrt 客户端（gfc-reverse-ssh + gfc-agent）
```

| 组件 | 职责 |
|------|------|
| `gfc-agent` | 心跳拉取 `reverse_ssh` 指令，维护 autossh |
| `gfc-reverse-ssh` | procd 托管 autossh，转发 SSH:212 与 HTTP:80 |
| 控制面 `reverse_ssh.py` | 端口池、会话 TTL、`authorized_keys` 同步 |
| 控制面 `remote_proxy.py` | LuCI / 刷码页 HTTP 反代与路径重写 |
| 控制面 `webssh.py` | 浏览器 WebSocket → 本地反向 SSH 端口 |

---

## 2. 会话生命周期

1. 管理员在 **客户端设备** 页点击「远程 SSH / Web 管理 / 刷码协助」
2. Web UI 调用 `POST /admin/client-devices/{id}/reverse-ssh/session`（`targets`: `ssh` / `web` / `flash`）
3. 控制面分配或复用 `(reverse_ssh_port, reverse_http_port)`，写入会话 TTL（默认 1800s）
4. 客户端下次心跳收到 `reverse_ssh` JSON → 启动/重启 autossh
5. 隧道就绪后：
   - **SSH**：`/client-devices/{id}/ssh` WebSSH 页
   - **Web**：`/remote/{id}/cgi-bin/luci/...` LuCI 反代
   - **Flash**：`/remote/{id}/flash/gfc/activate.html`

会话访问会滑动续期 TTL。会话过期后 autossh 在下次心跳时停止。

---

## 3. 端口池与冷却（P2-6）

| 环境变量 | 默认 | 说明 |
|----------|------|------|
| `GFC_CLIENT_SSH_PORT_BASE` | 6001 | 端口池起始 |
| `GFC_CLIENT_SSH_PORT_MAX` | 7999 | 端口池上限 |
| `GFC_CLIENT_PORTS_PER_DEVICE` | 2 | 每设备占用连续端口数（SSH + HTTP） |
| `GFC_REVERSE_SSH_PORT_RELEASE_COOLDOWN_SECONDS` | 3600 | 删除设备后端口冷却时间 |

删除设备记录时：
- API 要求 `confirm=true`
- 端口写入 `released_reverse_ports` 表，冷却期内不会被重新分配
- `authorized_keys` 立即同步移除该设备公钥

---

## 4. 网络变更后隧道恢复（P2-4）

| 触发点 | 行为 |
|--------|------|
| `apply-network` / UCI 网络重载 | 写入 `/var/run/gfc-restore-reverse-ssh`，重启活跃 autossh |
| `gfc-bootstrap --apply-network` | 同上 + 立即尝试 restart |
| `gfc-bootstrap --rollback-network` | 从 `/var/lib/gfc-client/backups/network-*` 恢复 `/etc/config/network` |
| `upgrade-runtime.sh` | 升级后若 autossh 在跑则 restart init |
| `gfc-agent` 每轮 tick | 消费 restore 标记，`ClearLastCommand` + 加快心跳 |

### apply-network 与 WAN 安全（A+C）

权威规范：[`gfc-client/docs/NETWORK_APPLY.md`](../../gfc-client/docs/NETWORK_APPLY.md)

- 无 `network-wan.json` 时：**先从当前 UCI 导入**生成该文件，不凭空写 dhcp
- 仅当 `network-wan.json` 存在时才写 `network.wan`（写前自动快照）
- `mode=dhcp` 时会清理 UCI 中残留的 `ipaddr/gateway`（修复 proto 与地址不一致）
- `mode=pppoe` 时写入 `username`/`password`，并清理 static 残留字段
- 回滚：`gfc-bootstrap --rollback-network`

---

## 5. WebSSH 认证

- 控制面自动生成 `/data/pki/webssh_id`，经心跳下发 `webssh_authorized_key` 到设备 `authorized_keys`
- WebSSH WebSocket 使用平台登录 JWT 鉴权
- 设备 shell 经 `127.0.0.1:{reverse_ssh_port}` 连接
- 浏览器端使用 **xterm.js** 终端仿真（支持 Backspace/Delete/方向键）；SSH 子进程 `TERM=xterm-256color`

---

## 6. 危险操作确认（P2-3）

Web UI 统一使用 `src/utils/dangerousConfirm.ts`：

- 删除客户端 / 线路 / Socks 代理
- 重置用户密码
- 打开远程 SSH / Web / 刷码（建立隧道前确认）

删除客户端 API：`DELETE /admin/client-devices/{id}?confirm=true`

---

## 7. 部署前置条件

控制面宿主机（见 `gfc-platform/deploy/control/setup-reverse-ssh.sh`）：

- `sshd` 监听 `GFC_REVERSE_SSH_SSHD_PORT`（默认 212）
- 用户 `gfc-reverse`，`authorized_keys` 路径 `GFC_REVERSE_SSH_AUTHORIZED_KEYS_PATH`
- API 容器可访问 `127.0.0.1:{端口池}`

Web UI nginx 需代理 `/remote/` 及裸 `/cgi-bin/`、`/luci-static/`（Referer 路由）。

---

## 8. 常用验证命令

见仓库根目录交付说明或运行：

```bash
# 控制面：端口池与冷却表
sqlite3 gfc.db "SELECT port, released_until FROM released_reverse_ports;"

# 设备：隧道状态
pidof autossh
/etc/init.d/gfc-reverse-ssh status
logread -e gfc-reverse

# 控制面：隧道探测
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:6001/   # 示例 SSH 端口
```

---

## 9. 相关代码路径

| 路径 | 说明 |
|------|------|
| `gfc-platform/control-plane/api/app/reverse_ssh.py` | 端口池、冷却、authorized_keys |
| `gfc-platform/control-plane/api/app/remote_proxy.py` | LuCI HTTP 反代 |
| `gfc-platform/control-plane/api/app/webssh.py` | WebSSH 桥 |
| `gfc-client/internal/reversessh/` | autossh 管理、网络恢复 |
| `gfc-client/internal/agent/runner.go` | 心跳同步隧道 |
| `gfc-platform/web-ui/src/lib/openRemote.ts` | 弹窗远程入口 |
