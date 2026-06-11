from __future__ import annotations

import ipaddress
from typing import Iterable

# Dedicated pool for OpenVPN site-to-site /30 links (VyOS .1, node .2 per /30).
TUNNEL_POOL = ipaddress.ip_network("10.255.0.0/16")
DEFAULT_TUNNEL_NETWORK = "10.255.0.0/30"


def parse_tunnel_network(tunnel_network: str | None) -> tuple[str, str]:
    """Return (vyos_tunnel_ip, node_tunnel_ip) from e.g. 10.255.0.0/30."""
    if not tunnel_network:
        return parse_tunnel_network(DEFAULT_TUNNEL_NETWORK)
    try:
        net = ipaddress.ip_network(tunnel_network.strip(), strict=False)
    except ValueError:
        return parse_tunnel_network(DEFAULT_TUNNEL_NETWORK)
    if net.prefixlen > 30:
        raise ValueError("隧道网段前缀长度应 <= /30（点对点链路）")
    hosts = list(net.hosts())
    if len(hosts) < 2:
        raise ValueError("隧道网段至少需要 2 个可用主机地址")
    return str(hosts[0]), str(hosts[1])


def _as_network(cidr: str) -> ipaddress.IPv4Network | None:
    cidr = (cidr or "").strip()
    if not cidr:
        return None
    try:
        return ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return None


def networks_overlap(a: str, b: str) -> bool:
    na, nb = _as_network(a), _as_network(b)
    if na is None or nb is None:
        return False
    return na.overlaps(nb)


def tunnel_conflicts(candidate: str, reserved: Iterable[str]) -> str | None:
    """Return conflict reason if candidate overlaps any reserved CIDR."""
    cand = _as_network(candidate)
    if cand is None:
        return "无效的隧道网段 CIDR"
    if not cand.subnet_of(TUNNEL_POOL):
        return f"隧道网段须在专用池 {TUNNEL_POOL} 内"
    if cand.prefixlen > 30:
        return "隧道网段前缀长度应 <= /30"
    hosts = list(cand.hosts())
    if len(hosts) < 2:
        return "隧道网段至少需要 2 个主机地址"
    for other in reserved:
        o = (other or "").strip()
        if not o:
            continue
        if networks_overlap(candidate, o):
            return f"与已有网段 {o} 重叠"
    return None


def allocate_tunnel_network(reserved: Iterable[str]) -> str:
    """Pick the first free /30 in TUNNEL_POOL that does not overlap reserved CIDRs."""
    reserved_list = [r.strip() for r in reserved if (r or "").strip()]
    # Walk /30 subnets: 10.255.0.0/30, 10.255.0.4/30, ...
    base = int(TUNNEL_POOL.network_address)
    broadcast = int(TUNNEL_POOL.broadcast_address)
    step = 4  # /30 size
    for net_int in range(base, broadcast - 2, step):
        net = ipaddress.ip_network((net_int, 30), strict=False)
        candidate = str(net)
        if tunnel_conflicts(candidate, reserved_list) is None:
            return candidate
    raise RuntimeError(f"隧道地址池 {TUNNEL_POOL} 已耗尽，请扩大池或清理旧配置")


def normalize_tunnel_network(cidr: str | None) -> str | None:
    if not (cidr or "").strip():
        return None
    net = _as_network(cidr)
    if net is None:
        return None
    return str(net)
