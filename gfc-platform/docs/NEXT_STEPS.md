# 下一步：打通节点与配置下发

控制平面 API + Web UI 已运行后，按此顺序验证。

## Web UI 报 Internal Server Error（转发节点/线路/健康检查）

节点 Agent 已上线但管理页 500，多为 **API 读取 SQLite 时间字段**（`last_seen_at` naive vs UTC）导致。请把最新 `control-plane/api` 同步到控制平面主机并 **重启 API**：

```bash
curl -fsS http://127.0.0.1:8080/admin/nodes | head
# 应返回 JSON 数组，而不是 Internal Server Error
```

修复后刷新 Web UI，应能看到 `MY-Node-01` 在线。

## 1. 同步最新代码到服务器

将以下更新同步到 `/var/socks/`（git pull 或 scp）：

- `control-plane/api/app/main.py`（含 `GET /admin/lines`）
- `web-ui/src/ui/App.tsx`（线路管理 UI）
- `scripts/verify-loop.sh`

重启 API；Web UI 若 dev 模式一般会自动热更新，否则重启 `npm run dev`。

## 2. API 冒烟测试（可选）

```bash
chmod +x /var/socks/scripts/verify-loop.sh
API=http://127.0.0.1:8080 /var/socks/scripts/verify-loop.sh
```

## 3. 部署 NodeAgent（转发节点）

**推荐**（整仓已拷到节点）：见 [NODE_DEPLOY.md](NODE_DEPLOY.md) → `sudo bash deploy/node/setup-after-copy.sh`

或手工前台调试：

```bash
cd /var/socks
cp deploy/node/node.env.example deploy/node/node.env
bash deploy/node/run-manual-debug.sh
```

成功后：

- Web UI「转发节点」表出现该节点，`最近心跳` 持续更新
- 本地生成 `./state/dataplane/config_bundle.json`

生产环境用 `deploy/vm/node-agent.service`。

## 4. Web UI 配置业务

1. **SOCKS 配置**：填写远端 SOCKS（host/port/账号）
2. **客户线路**：选节点 + SOCKS + 源 IP 段（客户经 VyOS 汇聚后的源地址段）
3. 保存后，NodeAgent 下次轮询会拉取新 `config_version`

## 5. 验证配置内容

在节点上：

```bash
cat /var/socks/node-agent/state/dataplane/config_bundle.json
```

应包含 `rules[].sourceCidrs` 与 `rules[].socks`。

## 6. 数据面（真实转发，后续）

参考 `deploy/dataplane/README.md`：nftables TPROXY + sing-box，由 NodeAgent 渲染配置（当前 MVP 仅落盘 JSON）。
