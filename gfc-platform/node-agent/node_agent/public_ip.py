"""Detect Internet-reachable IPv4 for forward-node VLESS endpoint reporting."""
from __future__ import annotations

import ipaddress
import logging
import os
import socket
import urllib.error
import urllib.request
from typing import Iterable

logger = logging.getLogger(__name__)

_HTTP_PROBE_URLS = (
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
    "https://ip.gs",
)
_HTTP_TIMEOUT = 4.0
_GCP_METADATA_URL = (
    "http://metadata.google.internal/computeMetadata/v1/"
    "instance/network-interfaces/0/access-configs/0/external-ip"
)


def is_globally_routable_ipv4(value: str | None) -> bool:
    """True when value is a public unicast IPv4 (not private / CGNAT / link-local)."""
    text = (value or "").strip()
    if not text:
        return False
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return False
    if addr.version != 4:
        return False
    return not (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr.is_unspecified
    )


def _env_override() -> str | None:
    for key in ("GFC_NODE_PUBLIC_IP", "GFC_PUBLIC_IP"):
        raw = (os.environ.get(key) or "").strip()
        if not raw:
            continue
        if is_globally_routable_ipv4(raw):
            return raw
        logger.warning("%s=%r is not a globally routable IPv4; ignoring", key, raw)
    return None


def _http_get_ip(url: str, headers: dict[str, str] | None = None) -> str | None:
    req = urllib.request.Request(url, headers=headers or {}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as resp:
            body = resp.read(64).decode("utf-8", errors="replace").strip()
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    # Some providers return trailing newlines or HTML; take first token.
    candidate = body.split()[0] if body else ""
    if is_globally_routable_ipv4(candidate):
        return candidate
    return None


def _probe_http(urls: Iterable[str] = _HTTP_PROBE_URLS) -> str | None:
    for url in urls:
        ip = _http_get_ip(url)
        if ip:
            return ip
    return None


def _probe_gcp_metadata() -> str | None:
    return _http_get_ip(
        _GCP_METADATA_URL,
        headers={"Metadata-Flavor": "Google"},
    )


def _probe_udp_source() -> str | None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return None
    if is_globally_routable_ipv4(ip):
        return ip
    return None


def detect_public_ip() -> str | None:
    """
    Best-effort public IPv4 for control-plane Node.public_ip / client VLESS server.

    Order: env override → GCP metadata → HTTP egress probes → UDP source (public only).
    Never returns RFC1918 / link-local / CGNAT addresses.
    """
    override = _env_override()
    if override:
        return override

    for name, fn in (
        ("gcp-metadata", _probe_gcp_metadata),
        ("http-egress", _probe_http),
        ("udp-source", _probe_udp_source),
    ):
        try:
            ip = fn()
        except Exception:  # noqa: BLE001 — detection must never crash agent loop
            logger.debug("public ip probe %s failed", name, exc_info=True)
            continue
        if ip:
            logger.info("detected public_ip=%s via %s", ip, name)
            return ip

    logger.warning(
        "public_ip detection failed (no globally routable IPv4); "
        "set GFC_NODE_PUBLIC_IP in /etc/gfc-node/gfc.env if this host is behind 1:1 NAT"
    )
    return None
