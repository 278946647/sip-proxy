from __future__ import annotations

import ipaddress
import os
import subprocess
from pathlib import Path
from typing import Any


# systemd openvpn@gfc-backbone expects /etc/openvpn/gfc-backbone.conf (not a subdir).
CONF_PATH = Path(os.environ.get("GFC_OPENVPN_CONF", "/etc/openvpn/gfc-backbone.conf"))
KEYS_DIR = Path(os.environ.get("GFC_OPENVPN_KEYS_DIR", "/etc/openvpn/gfc-backbone"))
LEGACY_CONF_PATH = KEYS_DIR / "gfc-backbone.conf"


def _write_file(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def disable_openvpn() -> tuple[bool, str]:
    unit = "openvpn@gfc-backbone"
    subprocess.run(["systemctl", "disable", unit], check=False, capture_output=True)
    r = subprocess.run(["systemctl", "stop", unit], capture_output=True, text=True, check=False)
    if r.returncode != 0:
        return True, "openvpn stopped"
    return True, "openvpn disabled"


def _tunnel_ips(tunnel_network: str | None) -> tuple[str, str]:
    """Return (vyos_tunnel_ip, node_tunnel_ip) from e.g. 10.255.0.0/30."""
    cidr = (tunnel_network or "10.255.0.0/30").strip()
    try:
        net = ipaddress.ip_network(cidr, strict=False)
        hosts = list(net.hosts())
        if len(hosts) >= 2:
            return str(hosts[0]), str(hosts[1])
    except ValueError:
        pass
    return "10.255.0.1", "10.255.0.2"


def _remove_legacy_conf() -> None:
    """Drop pre-fix path so systemd only sees control-plane-managed CONF_PATH."""
    if not LEGACY_CONF_PATH.is_file():
        return
    try:
        if LEGACY_CONF_PATH.resolve() != CONF_PATH.resolve():
            LEGACY_CONF_PATH.unlink()
    except OSError:
        pass


def apply_openvpn(vpn: dict[str, Any] | None) -> tuple[bool, str]:
    if not vpn or not vpn.get("enabled", True):
        return disable_openvpn()

    remote = vpn["remote"]
    port = int(vpn.get("port", 1194))
    proto = vpn.get("proto", "udp")
    dev = vpn.get("dev", "tun0")
    auth_mode = (vpn.get("auth_mode") or "pki").strip()

    lines = [
        f"dev {dev}",
        f"proto {proto}",
        f"remote {remote} {port}",
        "resolv-retry infinite",
        "nobind",
        "persist-key",
        "persist-tun",
        "verb 3",
    ]
    if vpn.get("extra_config"):
        lines.append(vpn["extra_config"])

    if auth_mode == "static_key":
        static_key = (vpn.get("static_key") or "").strip()
        if not static_key:
            return False, "static_key required for static_key auth_mode"
        vyos_ip, node_ip = _tunnel_ips(vpn.get("tunnel_network"))
        _write_file(KEYS_DIR / "static.key", static_key)
        lines.append(f"secret {KEYS_DIR / 'static.key'}")
        lines.append(f"ifconfig {node_ip} {vyos_ip}")
    else:
        lines.extend(["remote-cert-tls server", "client"])
        _write_file(KEYS_DIR / "ca.crt", vpn["ca"])
        _write_file(KEYS_DIR / "client.crt", vpn["cert"])
        _write_file(KEYS_DIR / "client.key", vpn["key"])
        if vpn.get("tls_auth"):
            _write_file(KEYS_DIR / "ta.key", vpn["tls_auth"])
        lines.extend(
            [
                f"ca {KEYS_DIR / 'ca.crt'}",
                f"cert {KEYS_DIR / 'client.crt'}",
                f"key {KEYS_DIR / 'client.key'}",
            ]
        )
        if vpn.get("tls_auth"):
            lines.append(f"tls-auth {KEYS_DIR / 'ta.key'} 1")

    _write_file(CONF_PATH, "\n".join(lines) + "\n", 0o644)
    _remove_legacy_conf()

    unit = "openvpn@gfc-backbone"
    subprocess.run(["systemctl", "enable", unit], check=False, capture_output=True)
    r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
    if r.returncode != 0:
        subprocess.run(["systemctl", "disable", unit], check=False, capture_output=True)
        subprocess.run(["systemctl", "stop", unit], check=False, capture_output=True)
        err = (r.stderr or r.stdout or "openvpn restart failed").strip()
        return False, f"{err} (config: {CONF_PATH})"
    return True, f"openvpn applied ({CONF_PATH})"
