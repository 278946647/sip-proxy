#!/usr/bin/env bash
# Minimal local status UI (reads /var/lib/gfc-client/status.json)
set -euo pipefail
PORT="${GFC_CLIENT_WEB_PORT:-8787}"
ROOT="${GFC_CLIENT_WEB_ROOT:-/opt/gfc-client/client-web}"
mkdir -p "$ROOT"
if [[ ! -f "$ROOT/index.html" ]]; then
  cat >"$ROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <title>GFC Client</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem; background: #f8fafc; }
    .card { background: #fff; padding: 1.5rem; border-radius: 12px; max-width: 720px; box-shadow: 0 1px 3px #0001; }
    h1 { margin-top: 0; }
    pre { background: #0f172a; color: #e2e8f0; padding: 1rem; border-radius: 8px; overflow: auto; }
  </style>
</head>
<body>
  <div class="card">
    <h1>GFC 客户端状态</h1>
    <p>本地管理页 · 数据来自 Agent 心跳快照</p>
    <pre id="out">loading...</pre>
  </div>
  <script>
    async function load() {
      const r = await fetch('/api/status');
      document.getElementById('out').textContent = JSON.stringify(await r.json(), null, 2);
    }
    load();
    setInterval(load, 5000);
  </script>
</body>
</html>
HTML
fi
cd "$ROOT"
exec python3 - <<PY
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

STATUS = Path(os.environ.get("GFC_STATUS_FILE", "/var/lib/gfc-client/status.json"))
PORT = int(os.environ.get("GFC_CLIENT_WEB_PORT", "8787"))
ROOT = Path(os.environ.get("GFC_CLIENT_WEB_ROOT", "/opt/gfc-client/client-web"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/status":
            data = {}
            if STATUS.is_file():
                data = json.loads(STATUS.read_text(encoding="utf-8"))
            body = json.dumps(data, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        rel = "index.html" if self.path in ("/", "") else self.path.lstrip("/")
        fp = ROOT / rel
        if not fp.is_file():
            self.send_error(404)
            return
        content = fp.read_bytes()
        ctype = "text/html" if fp.suffix == ".html" else "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, fmt, *args):
        return


HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY
