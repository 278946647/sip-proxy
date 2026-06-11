#!/usr/bin/env bash
# 在转发节点上测试 SOCKS5 连通性与认证（对照 sing-box 配置）
# 用法: sudo bash deploy/node/test-socks.sh [config_bundle.json]
set -euo pipefail

BUNDLE="${1:-/opt/gfc-node/node-agent/state/dataplane/config_bundle.json}"
SINGBOX="${SINGBOX:-/etc/gfc-node/sing-box.json}"

if [[ ! -f "$BUNDLE" && -f "$SINGBOX" ]]; then
  echo "==> 从 $SINGBOX 读取 outbound"
  python3 - "$SINGBOX" <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for ob in cfg.get("outbounds") or []:
    if ob.get("type") != "socks":
        continue
    print(f"tag={ob.get('tag')} host={ob.get('server')}:{ob.get('server_port')}")
    print(f"  username={ob.get('username')!r} password_set={bool(ob.get('password'))}")
PY
  exit 0
fi

[[ -f "$BUNDLE" ]] || { echo "缺少 $BUNDLE"; exit 1; }

echo "==> 配置 bundle: $BUNDLE"
python3 - "$BUNDLE" <<'PY'
import json, subprocess, sys
from pathlib import Path

bundle = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rules = (bundle.get("dataplane") or {}).get("rules") or []
if not rules:
    print("WARN: bundle 中无线路规则")
    sys.exit(1)

for i, rule in enumerate(rules):
    s = rule.get("socks") or {}
    host, port = s.get("host"), s.get("port")
    user, pw = (s.get("username") or "").strip(), (s.get("password") or "").strip()
    cidrs = rule.get("sourceCidrs") or []
    print(f"\n--- line {i} cidrs={cidrs}")
    print(f"    SOCKS {host}:{port}")
    print(f"    username={user!r}  password_len={len(pw)}")
    if user and not pw:
        print("    WARN: 有用户名但密码为空")
    if not user and pw:
        print("    WARN: 有密码但用户名为空")

    if not host or not port:
        print("    SKIP: 缺少 host/port")
        continue

    proxy = f"socks5://{host}:{port}"
    if user:
        # curl 需 URL 编码特殊字符；简单密码可直接用
        proxy = f"socks5://{user}:{pw}@{host}:{port}"

    print(f"    测试: curl -x {proxy} https://api.ipify.org")
    r = subprocess.run(
        ["curl", "-fsS", "--connect-timeout", "12", "-x", proxy, "https://api.ipify.org"],
        capture_output=True,
        text=True,
    )
    if r.returncode == 0:
        print(f"    OK 出口 IP: {r.stdout.strip()}")
    else:
        err = (r.stderr or r.stdout or "curl failed").strip()
        print(f"    FAIL: {err}")
        if "auth" in err.lower() or "password" in err.lower() or "407" in err:
            print("    => SOCKS 用户名或密码错误，请在控制台「Socks5 代理配置」中修正后等待下发")
PY
