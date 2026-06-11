#!/usr/bin/env python3
"""Forward node one-shot repair implementation (invoked by repair_forward_node.py)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

_DIR = Path(__file__).resolve().parent
if str(_DIR) not in sys.path:
    sys.path.insert(0, str(_DIR))

from crlf_util import fix_tree, patch_corrupted_python  # noqa: E402

REPO = Path(os.environ.get("REPO_ROOT", "/var/socks"))
GFC_ROOT = Path(os.environ.get("GFC_ROOT", "/opt/gfc-node"))
SINGBOX_VERSION = os.environ.get("SINGBOX_VERSION", "1.13.4")
STATE_FILE = GFC_ROOT / "node-agent/state/node_state.json"
BUNDLE_FILE = GFC_ROOT / "node-agent/state/dataplane/config_bundle.json"
SINGBOX_JSON = Path("/etc/gfc-node/sing-box.json")
VENV_PY = GFC_ROOT / "node-agent/.venv/bin/python"
GFC_ENV = Path("/etc/gfc-node/gfc.env")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd))
    return subprocess.run(cmd, check=False, **kwargs)


def load_env() -> dict[str, str]:
    out: dict[str, str] = {}
    if not GFC_ENV.is_file():
        return out
    for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def sync_node_agent() -> None:
    src = REPO / "node-agent"
    dst = GFC_ROOT / "node-agent"
    if not src.is_dir():
        raise SystemExit(f"missing {src}")
    print(f"==> Sync {src} -> {dst}")
    for item in dst.iterdir():
        if item.name in {".venv", "state"}:
            continue
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
    for item in src.iterdir():
        if item.name in {".venv", "state"}:
            continue
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)


def ensure_venv() -> None:
    if not VENV_PY.is_file():
        print("==> Create venv")
        run(["python3", "-m", "venv", str(GFC_ROOT / "node-agent/.venv")])
    run([str(VENV_PY), "-m", "pip", "install", "-q", "-U", "pip"])
    run(
        [
            str(VENV_PY),
            "-m",
            "pip",
            "install",
            "-q",
            "-r",
            str(GFC_ROOT / "node-agent/requirements.txt"),
        ]
    )


def ensure_network_tuning() -> None:
    sys.path.insert(0, str(GFC_ROOT / "node-agent"))
    try:
        from node_agent.sysctl_util import ensure_network_tuning as _tune

        print("==> Network tuning:", _tune())
    except Exception as exc:
        print(f"WARN network tuning: {exc}")


def install_singbox() -> None:
    run(["systemctl", "stop", "gfc-sing-box"], capture_output=True)

    arch = "amd64" if os.uname().machine in {"x86_64", "amd64"} else "arm64"
    if SINGBOX_VERSION == "latest":
        req = urllib.request.Request(
            "https://api.github.com/repos/SagerNet/sing-box/releases/latest",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "gfc-installer"},
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        ver = data["tag_name"].lstrip("v")
        name = f"sing-box-{ver}-linux-{arch}.tar.gz"
        url = next(a["browser_download_url"] for a in data["assets"] if a["name"] == name)
    else:
        ver = SINGBOX_VERSION
        url = (
            f"https://github.com/SagerNet/sing-box/releases/download/v{ver}/"
            f"sing-box-{ver}-linux-{arch}.tar.gz"
        )
    print(f"==> Install sing-box {ver}")
    print(f"    {url}")
    with tempfile.TemporaryDirectory() as tmp:
        tgz = Path(tmp) / "sb.tgz"
        urllib.request.urlretrieve(url, tgz)
        with tarfile.open(tgz) as tf:
            tf.extractall(tmp)
        binary = next(p for p in Path(tmp).rglob("sing-box") if p.is_file())
        dest = Path("/usr/local/bin/sing-box")
        staging = dest.with_suffix(".new")
        shutil.copy2(binary, staging)
        os.chmod(staging, 0o755)
        staging.replace(dest)
    r = run(["sing-box", "version"])
    if r.stdout:
        print("   ", r.stdout.strip().splitlines()[0])


def render_singbox() -> None:
    if not BUNDLE_FILE.is_file() or not VENV_PY.is_file():
        print("WARN skip render: missing bundle or venv")
        return
    print(f"==> Render {SINGBOX_JSON}")
    sys.path.insert(0, str(GFC_ROOT / "node-agent"))
    from node_agent.singbox import render_singbox_config

    bundle = json.loads(BUNDLE_FILE.read_text(encoding="utf-8"))
    cfg = render_singbox_config(bundle.get("dataplane") or {})
    SINGBOX_JSON.parent.mkdir(parents=True, exist_ok=True)
    SINGBOX_JSON.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"    OK wrote {SINGBOX_JSON}")


def clear_applied_version() -> None:
    if not STATE_FILE.is_file():
        return
    data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    data.pop("applied_version", None)
    STATE_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"==> Cleared applied_version in {STATE_FILE}")


def singbox_check() -> bool:
    if not SINGBOX_JSON.is_file():
        print("ERROR missing sing-box.json")
        return False
    r = run(["sing-box", "check", "-c", str(SINGBOX_JSON)])
    ok = r.returncode == 0
    if not ok:
        print((r.stderr or r.stdout or "sing-box check failed").strip())
    return ok


def verify_node() -> None:
    env = load_env()
    api = env.get("SERVER_URL") or env.get("API") or "http://127.0.0.1:8080"
    node_name = env.get("NODE_NAME", "")

    print("==> Verify forward node")
    for unit in ("gfc-node-agent", "gfc-sing-box"):
        r = run(["systemctl", "is-active", unit])
        status = (r.stdout or "").strip() or f"exit={r.returncode}"
        print(f"    {unit}: {status}")

    if STATE_FILE.is_file():
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        print(f"    node_id: {data.get('node_id')}")
        print(f"    has token: {bool(data.get('node_token'))}")
    else:
        print(f"    WARN missing {STATE_FILE}")

    if BUNDLE_FILE.is_file():
        bundle = json.loads(BUNDLE_FILE.read_text(encoding="utf-8"))
        dp = bundle.get("dataplane") or {}
        rules = dp.get("rules") or bundle.get("rules") or []
        routes = bundle.get("staticRoutes") or []
        print(f"    rules: {len(rules)}, staticRoutes: {len(routes)}")
    else:
        print(f"    WARN missing {BUNDLE_FILE}")

    if singbox_check():
        print("    sing-box check: OK")

    for key in ("net.ipv4.ip_forward", "net.ipv4.tcp_congestion_control", "net.core.default_qdisc"):
        r = run(["sysctl", "-n", key])
        print(f"    {key}={(r.stdout or '').strip()}")

    fd, tmp_path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    tmp = Path(tmp_path)
    try:
        r = run(["curl", "-fsS", f"{api.rstrip('/')}/admin/nodes", "-o", str(tmp)])
        if r.returncode == 0 and node_name:
            nodes = json.loads(tmp.read_text(encoding="utf-8"))
            for n in nodes:
                if n.get("name") == node_name:
                    print(
                        f"    API node {node_name}: online={n.get('online')} "
                        f"lastSeenAt={n.get('lastSeenAt')}"
                    )
                    break
            else:
                print(f"    WARN node {node_name} not in admin list")
        elif r.returncode != 0:
            print(f"    WARN could not fetch {api}/admin/nodes")
    finally:
        tmp.unlink(missing_ok=True)


def main() -> int:
    if os.geteuid() != 0:
        print("请用 root 执行: sudo python3", REPO / "deploy/node/repair_forward_node.py")
        return 1

    print("==> GFC 转发节点一键修复")
    print(f"    仓库: {REPO}")
    print(f"    安装: {GFC_ROOT}")

    patched = patch_corrupted_python(REPO / "deploy/node")
    if patched:
        print(f"==> 已修复损坏的 Python 脚本: {patched} 个")

    n = fix_tree(REPO)
    print(f"==> CRLF 修复: {n} 个文件")

    sync_node_agent()
    ensure_venv()
    ensure_network_tuning()
    install_singbox()
    render_singbox()

    if not singbox_check():
        print("ERROR sing-box 配置校验失败")
        return 1

    clear_applied_version()

    print("==> 重启服务")
    run(["systemctl", "restart", "gfc-node-agent"])
    time.sleep(12)
    run(["systemctl", "restart", "gfc-sing-box"])
    time.sleep(2)

    run(["journalctl", "-u", "gfc-node-agent", "-n", "12", "--no-pager"])
    verify_node()

    print("==> 修复完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
