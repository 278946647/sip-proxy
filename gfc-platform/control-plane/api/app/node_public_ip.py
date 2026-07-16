"""Validate node public_ip values used as VLESS endpoints."""
from __future__ import annotations

import ipaddress
import logging

logger = logging.getLogger(__name__)


def normalize_node_public_ip(value: str | None) -> str | None:
    """
    Accept only globally routable IPv4 for Node.public_ip.

    Private / CGNAT / link-local values are dropped so cloud VMs behind 1:1 NAT
    cannot poison client VLESS server addresses.
    """
    text = (value or "").strip()
    if not text:
        return None
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        logger.warning("ignoring invalid node public_ip=%r", text)
        return None
    if addr.version != 4:
        logger.warning("ignoring non-IPv4 node public_ip=%r", text)
        return None
    if (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr.is_unspecified
    ):
        logger.warning("ignoring non-public node public_ip=%s", text)
        return None
    return text
