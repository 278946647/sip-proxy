# 首次推送到 GitHub

仓库：https://github.com/278946647/sip-proxy.git  
**Git 根目录：** `sip-proxy/`（含 `gfc-platform/` 与 `gfc-client/`）

---

## 1. 初始化（已完成可跳过）

```powershell
cd C:\Users\Administrator\Desktop\sip-proxy
git init -b main
git remote add origin https://github.com/278946647/sip-proxy.git
```

---

## 2. 认证

**HTTPS + Token：** GitHub → Settings → Developer settings → Personal access tokens → 勾选 `repo`

**SSH：**

```powershell
git remote set-url origin git@github.com:278946647/sip-proxy.git
```

---

## 3. 首次提交与推送

```powershell
cd C:\Users\Administrator\Desktop\sip-proxy

git status
git add .
git commit -m "Initial commit: gfc-platform and gfc-client monorepo"
git push -u origin main
```

远程已有 README 时：

```powershell
git pull origin main --allow-unrelated-histories
git push -u origin main
```

---

## 4. 目录约定

| 路径 | 推送 | 服务器克隆后 |
|------|------|--------------|
| `gfc-platform/` | ✅ | `cd gfc-platform` 再装控制面/节点 |
| `gfc-client/` | ✅ | 仅客户端机器需要；可只 scp 此目录 |
| `gfc-client/dist/` | ❌ (.gitignore) | 本地 `pack-offline.sh` 产物 |

---

## 5. 服务器拉取

```bash
git clone https://github.com/278946647/sip-proxy.git /opt/sip-proxy
cd /opt/sip-proxy/gfc-platform && sudo bash deploy/control/install-docker.sh
```

客户端离线包在构建机：

```bash
cd /opt/sip-proxy/gfc-client && bash deploy/pack-offline.sh
```

---

## 6. 勿提交

`.gitignore` 已排除：`.env`、`*.db`、`data/pki/`、`.venv/`、`node_modules/`、`dist/`
