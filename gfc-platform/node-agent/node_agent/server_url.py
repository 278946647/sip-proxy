"""Control plane API base URL helpers (IP or domain, optional fallback)."""
from __future__ import annotations

import ipaddress
import os
import re
from typing import Any
from urllib.parse import urlparse

DEFAULT_API_PORT = 8080
DEFAULT_SCHEME = "http"


def _is_ipv6(host: str) -> bool:
    try:
        ipaddress.IPv6Address(host)
        return True
    except ValueError:
        return False


def _format_host_port(host: str, port: int, scheme: str) -> str:
    host = host.strip()
    if not host:
        raise ValueError("empty host")
    if _is_ipv6(host) and not host.startswith("["):
        host = f"[{host}]"
    if (scheme == "http" and port == 80) or (scheme == "https" and port == 443):
        return f"{scheme}://{host}"
    return f"{scheme}://{host}:{port}"


def normalize_server_url(
    value: str,
    *,
    default_port: int = DEFAULT_API_PORT,
    default_scheme: str = DEFAULT_SCHEME,
) -> str:
    raw = (value or "").strip()
    if not raw:
        raise ValueError("empty server URL")

    if "://" in raw:
        parsed = urlparse(raw)
        scheme = (parsed.scheme or default_scheme).lower()
        host = (parsed.hostname or "").strip()
        if not host:
            raise ValueError(f"invalid server URL: {value!r}")
        port = parsed.port or default_port
        return _format_host_port(host, port, scheme)

    if raw.startswith("["):
        m = re.match(r"^\[([^\]]+)\](?::(\d+))?$", raw)
        if not m:
            raise ValueError(f"invalid IPv6 host: {value!r}")
        host = m.group(1)
        port = int(m.group(2)) if m.group(2) else default_port
        return _format_host_port(host, port, default_scheme)

    if ":" in raw and raw.rsplit(":", 1)[-1].isdigit():
        host, port_s = raw.rsplit(":", 1)
        return _format_host_port(host, port_s, default_scheme)

    return _format_host_port(raw, default_port, default_scheme)


def parse_server_url_list(*values: str | None) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for value in values:
        if not value:
            continue
        for part in str(value).split(","):
            part = part.strip()
            if not part:
                continue
            try:
                url = normalize_server_url(part)
            except ValueError:
                continue
            if url not in seen:
                seen.add(url)
                out.append(url)
    return out


def resolve_server_urls_from_env() -> list[str]:
    return parse_server_url_list(
        os.environ.get("SERVER_URL"),
        os.environ.get("SERVER_URL_FALLBACK"),
        os.environ.get("SERVER_URLS"),
    )
