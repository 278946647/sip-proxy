"""AmneziaWG server-side config rendering and lifecycle (forward node).

The kernel module (kmod-amneziawg / amneziawg-tools) terminates awg0; traffic
then enters the existing TPROXY path (mark 0x100 -> table 100). No nft rules
are written here — see nft_render.py.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

AWG_IFACE = "awg0"
AWG_DIR = Path(os.environ.get("GFC_AWG_DIR", "/etc/amnezia/amneziawg"))
AWG_CONF = AWG_DIR / "awg0.conf"
AWG_STATE = AWG_DIR / "awg0.applied"

_REQUIRED_PARAMS = ("jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4")


def _key_ok(value: Any) -> bool:
    text = str(value or "").strip()
    return bool(re.fullmatch(r"[A-Za-z0-9+/]{43}=", text))


def _interface(awg: dict[str, Any]) -> dict[str, Any]:
    return {
        "serverInnerIp": str(awg.get("serverInnerIp") or "").strip(),
        "listenPort": int(awg.get("listenPort") or 51820),
        "mtu": int(awg.get("mtu") or 1408),
        "privateKey": str(awg.get("serverPrivateKey") or "").strip(),
        "paramsVersion": int(awg.get("paramsVersion") or 1),
        "obfuscation": dict(awg.get("obfuscation") or {}),
        "peers": [p for p in (awg.get("peers") or []) if isinstance(p, dict)],
    }


def validate_awg_config(awg: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    cfg = _interface(awg)
    if not cfg["serverInnerIp"]:
        errors.append("serverInnerIp 缺失")
    if not _key_ok(cfg["privateKey"]):
        errors.append("serverPrivateKey 非法")
    if cfg["listenPort"] <= 0 or cfg["listenPort"] > 65535:
        errors.append("listenPort 超出范围")
    if cfg["mtu"] < 1280 or cfg["mtu"] > 1420:
        errors.append("mtu 超出范围 1280..1420")
    params = cfg["obfuscation"]
    for name in _REQUIRED_PARAMS:
        if name not in params:
            errors.append(f"obfuscation 缺少 {name}")
    if not cfg["peers"]:
        errors.append("peers 为空")
    for peer in cfg["peers"]:
        if not _key_ok(peer.get("publicKey")):
            errors.append(f"peer {peer.get('lineId')} publicKey 非法")
        if not str(peer.get("innerIp") or "").endswith("/32"):
            errors.append(f"peer {peer.get('lineId')} innerIp 必须是 /32")
    return errors


def render_awg_config(awg: dict[str, Any]) -> str:
    cfg = _interface(awg)
    params = cfg["obfuscation"]
    lines = [
        "[Interface]",
        f"Address = {cfg['serverInnerIp']}",
        f"ListenPort = {cfg['listenPort']}",
        f"MTU = {cfg['mtu']}",
        f"PrivateKey = {cfg['privateKey']}",
        # Table=auto installs a /32 return route for every peer.
        "Table = auto",
        f"Jc = {int(params.get('jc', 0))}",
        f"Jmin = {int(params.get('jmin', 0))}",
        f"Jmax = {int(params.get('jmax', 0))}",
        f"S1 = {int(params.get('s1', 0))}",
        f"S2 = {int(params.get('s2', 0))}",
        f"H1 = {int(params.get('h1', 0))}",
        f"H2 = {int(params.get('h2', 0))}",
        f"H3 = {int(params.get('h3', 0))}",
        f"H4 = {int(params.get('h4', 0))}",
        "PostUp = sysctl -w net.ipv4.ip_forward=1",
        "PostDown = true",
    ]
    for name in ("s3", "s4"):
        if name in params:
            lines.append(f"{name.upper()} = {int(params[name])}")
    for peer in cfg["peers"]:
        lines.extend(
            [
                "",
                "[Peer]",
                f"PublicKey = {str(peer.get('publicKey') or '').strip()}",
            ]
        )
        psk = str(peer.get("presharedKey") or "").strip()
        if psk:
            lines.append(f"PresharedKey = {psk}")
        lines.append(f"AllowedIPs = {str(peer.get('innerIp') or '').strip()}")
    return "\n".join(lines) + "\n"


def awg_iface_up() -> bool:
    return subprocess.run(
        ["ip", "link", "show", AWG_IFACE], capture_output=True, text=True, check=False
    ).returncode == 0


def _run(cmd: list[str]) -> tuple[bool, str]:
    r = subprocess.run(cmd, capture_output=True, text=True, check=False)
    return r.returncode == 0, (r.stderr or r.stdout or "").strip()


def apply_awg(awg: dict[str, Any] | None) -> tuple[bool, str]:
    """Render + apply awg0. Idempotent; restores the previous config on failure."""
    if not awg or not awg.get("enabled"):
        return True, "awg disabled"
    errors = validate_awg_config(awg)
    if errors:
        return False, "awg config invalid: " + "; ".join(errors)

    text = render_awg_config(awg)
    AWG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(AWG_DIR, 0o700)
    backup = AWG_DIR / "awg0.conf.bak"
    if AWG_CONF.exists():
        try:
            if AWG_CONF.read_text(encoding="utf-8") == text and awg_iface_up():
                return True, f"awg unchanged ({AWG_IFACE} up)"
            shutil.copy2(AWG_CONF, backup)
        except OSError:
            pass
    tmp = AWG_DIR / "awg0.conf.tmp"
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(AWG_CONF)
    os.chmod(AWG_CONF, 0o600)

    if awg_iface_up():
        _run(["awg-quick", "down", AWG_IFACE])
    ok, msg = _run(["awg-quick", "up", AWG_IFACE])
    if ok:
        AWG_STATE.write_text(
            str(int(awg.get("paramsVersion") or 0)), encoding="utf-8"
        )
        return True, f"awg0 up (port {_interface(awg)['listenPort']})"
    if backup.exists():
        try:
            shutil.copy2(backup, AWG_CONF)
            os.chmod(AWG_CONF, 0o600)
            _run(["awg-quick", "up", AWG_IFACE])
        except OSError:
            pass
    return False, "awg-quick up failed: " + msg


def peers_dump() -> list[dict[str, Any]]:
    """Parse `awg show awg0 dump`; never invents connection state."""
    ok, out = _run(["awg", "show", AWG_IFACE, "dump"])
    if not ok or not out:
        return []
    now = int(time.time())
    peers: list[dict[str, Any]] = []
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        allowed = parts[3].split(",")[0].strip()
        try:
            handshake = int(parts[4])
            rx = int(parts[5])
            tx = int(parts[6])
        except ValueError:
            continue
        age = 0 if handshake <= 0 else max(0, now - handshake)
        peers.append(
            {
                "publicKey": parts[0],
                "innerIp": allowed if "/" in allowed else f"{allowed}/32",
                "handshakeAgeSec": age,
                "rxBytes": rx,
                "txBytes": tx,
            }
        )
    return peers


def collect_awg_metrics(awg: dict[str, Any] | None) -> dict[str, Any]:
    if not awg or not awg.get("enabled"):
        return {}
    peers = peers_dump()
    return {
        "iface": AWG_IFACE,
        "ifaceUp": awg_iface_up(),
        "listenPort": int(awg.get("listenPort") or 51820),
        "paramsVersion": int(awg.get("paramsVersion") or 1),
        "peerCount": len(peers),
        "peers": peers,
    }
