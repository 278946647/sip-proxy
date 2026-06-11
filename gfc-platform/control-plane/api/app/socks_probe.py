from __future__ import annotations

import shutil
import subprocess
from typing import Any

from .socks_parse import format_socks_address


def probe_socks(
    host: str,
    port: int,
    username: str | None,
    password: str | None,
    *,
    probe_url: str,
    timeout_seconds: int,
) -> tuple[bool, str]:
    """Test SOCKS5 by curling probe_url through the proxy (exit IP in body on success)."""
    if not shutil.which("curl"):
        return False, "curl not installed — install curl in API image/host"
    host = (host or "").strip()
    if not host or not port:
        return False, "missing host or port"

    user = (username or "").strip()
    pw = (password or "").strip()
    proxy = f"socks5://{host}:{port}"
    if user:
        proxy = f"socks5://{user}:{pw}@{host}:{port}"

    try:
        r = subprocess.run(
            [
                "curl",
                "-fsS",
                "--connect-timeout",
                str(timeout_seconds),
                "-x",
                proxy,
                probe_url,
            ],
            capture_output=True,
            text=True,
            timeout=timeout_seconds + 5,
        )
        if r.returncode == 0 and (r.stdout or "").strip():
            return True, f"exit_ip={r.stdout.strip()}"
        err = (r.stderr or r.stdout or "curl failed").strip()
        return False, err[:240]
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)[:240]


def socks_profile_fields(sp: Any) -> dict[str, Any]:
    return {
        "host": sp.host,
        "port": sp.port,
        "username": sp.username,
        "password": sp.password,
        "address": format_socks_address(sp.host, sp.port, sp.username, sp.password),
    }
