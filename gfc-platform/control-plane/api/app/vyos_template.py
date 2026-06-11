from __future__ import annotations

from typing import Any

from .tunnel_pool import parse_tunnel_network


def render_vyos_openvpn_server(
    *,
    node_name: str,
    node_public_ip: str | None,
    vpn: dict[str, Any],
    line_cidrs: list[str],
) -> str:
    """Generate VyOS CLI hints for site-to-site OpenVPN server (manual apply on VyOS)."""
    remote = vpn.get("remote") or "<vyos-wan-ip>"
    port = int(vpn.get("port") or 1194)
    proto = vpn.get("proto") or "udp"
    tunnel_network = vpn.get("tunnel_network") or "10.255.0.0/30"
    vyos_ip, node_ip = parse_tunnel_network(tunnel_network)

    remote_networks: list[str] = []
    for c in vpn.get("remote_networks") or []:
        c = str(c).strip()
        if c:
            remote_networks.append(c)
    for c in line_cidrs:
        c = str(c).strip()
        if c and c not in remote_networks:
            remote_networks.append(c)

    node_wan = node_public_ip or "<forward-node-public-ip>"
    auth_mode = (vpn.get("auth_mode") or "pki").strip()
    prefix_len = tunnel_network.split("/")[-1] if "/" in tunnel_network else "30"
    lines = [
        "# VyOS OpenVPN site-to-site (server) — paste/adapt on backbone router",
        f"# Forward node: {node_name} ({node_wan})",
        f"# Match control-plane client remote -> this VyOS WAN: {remote}",
        f"# Auth mode: {auth_mode}",
        "",
        "set interfaces openvpn vtun0 mode 'site-to-site'",
        f"set interfaces openvpn vtun0 protocol '{proto}'",
        f"set interfaces openvpn vtun0 persistent-tunnel",
        f"set interfaces openvpn vtun0 local-address '{vyos_ip}/{prefix_len}'",
        f"set interfaces openvpn vtun0 remote-address '{node_ip}'",
        f"set interfaces openvpn vtun0 remote-host '{node_wan}'",
        f"set interfaces openvpn vtun0 remote-port '{port}'",
    ]
    if auth_mode == "static_key":
        lines.extend(
            [
                "set interfaces openvpn vtun0 shared-secret-key-file '/config/auth/gfc-static.key'",
                "",
                "# Upload the same static key from control-plane to VyOS:",
                "#   scp gfc-static.key vyos@<vyos>:/config/auth/gfc-static.key",
                "# Or on VyOS: generate openvpn key /config/auth/gfc-static.key",
                "# then paste the control-plane key content into that file.",
            ]
        )
    else:
        lines.extend(
            [
                "set interfaces openvpn vtun0 tls ca-cert-file '/config/auth/gfc-ca.crt'",
                "set interfaces openvpn vtun0 tls cert-file '/config/auth/gfc-server.crt'",
                "set interfaces openvpn vtun0 tls key-file '/config/auth/gfc-server.key'",
                "",
                "# Upload CA / server cert / key from control-plane PKI (server role) to VyOS /config/auth/",
                "# Client cert on forward node is issued via 控制台 -> OpenVPN -> 生成客户端证书",
            ]
        )
    lines.extend(
        [
            "",
            "# Route customer / backbone networks toward forward node via tunnel",
        ]
    )
    for cidr in remote_networks:
        lines.append(f"set protocols static route {cidr} next-hop '{node_ip}'")
    if not remote_networks:
        lines.append("# set protocols static route <customer-cidr> next-hop '<node_tunnel_ip>'")

    lines.extend(
        [
            "",
            "# Ensure VyOS sends traffic to forward node TPROXY ingress (tunnel or eth link)",
            f"# Forward node OpenVPN client uses dev {vpn.get('dev') or 'tun0'}; set GFC_TPROXY_IFACE accordingly",
            "",
            "# After commit: commit; save",
        ]
    )
    return "\n".join(lines) + "\n"
