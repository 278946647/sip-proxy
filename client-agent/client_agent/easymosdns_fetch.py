from __future__ import annotations

import shutil
import subprocess
import urllib.error
import urllib.request

GITHUB_BASE = "https://raw.githubusercontent.com/pmkol/easymosdns/rules"
CDN_BASE = "https://fastly.jsdelivr.net/gh/pmkol/easymosdns@rules"
BOOTSTRAP_DNS = ("223.5.5.5", "119.29.29.29", "8.8.8.8", "1.1.1.1")


def _fetch_curl(url: str, timeout: int = 180) -> bytes:
    dns_args: list[str] = []
    for addr in BOOTSTRAP_DNS:
        dns_args.extend(["--dns-servers", addr])
    cmd = [
        "curl",
        "-fsSL",
        "--connect-timeout",
        "20",
        "--max-time",
        str(timeout),
        *dns_args,
        url,
    ]
    r = subprocess.run(cmd, capture_output=True, check=False)
    if r.returncode == 0 and r.stdout:
        return r.stdout
    err = (r.stderr or b"").decode("utf-8", errors="replace").strip()
    raise RuntimeError(err or f"curl failed ({r.returncode})")


def fetch(url: str, timeout: int = 120) -> bytes:
    if shutil.which("curl"):
        try:
            return _fetch_curl(url, timeout=timeout)
        except RuntimeError:
            pass
    req = urllib.request.Request(url, headers={"User-Agent": "gfc-client-agent/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.URLError as exc:
        raise RuntimeError(f"download failed: {exc}") from exc
