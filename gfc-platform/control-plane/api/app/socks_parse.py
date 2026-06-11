from __future__ import annotations

import re
from typing import Any

# username:password@host:port  (IPv4 host; port 1-65535)
SOCKS_ADDRESS_RE = re.compile(
    r"^(?:(?P<username>[^:]+):(?P<password>[^@]+)@)?(?P<host>\d{1,3}(?:\.\d{1,3}){3}|[a-zA-Z0-9.-]+):(?P<port>\d{1,5})$"
)


def parse_socks_address(address: str) -> dict[str, Any]:
    """Parse momoproxy-style SOCKS URI into host/port/credentials."""
    raw = address.strip()
    if not raw:
        raise ValueError("代理地址不能为空")
    m = SOCKS_ADDRESS_RE.match(raw)
    if not m:
        raise ValueError(
            "格式应为 username:password@IP:Port（无认证时可写 host:port）"
        )
    port = int(m.group("port"))
    if port < 1 or port > 65535:
        raise ValueError("端口须在 1-65535")
    return {
        "host": m.group("host"),
        "port": port,
        "username": m.group("username"),
        "password": m.group("password"),
    }


def format_socks_address(
    host: str,
    port: int,
    username: str | None,
    password: str | None,
) -> str:
    if username:
        return f"{username}:{password or ''}@{host}:{port}"
    return f"{host}:{port}"
