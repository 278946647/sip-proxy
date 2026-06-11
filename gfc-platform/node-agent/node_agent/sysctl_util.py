from __future__ import annotations

import subprocess
from pathlib import Path

SYSCTL_DROPIN = Path("/etc/sysctl.d/99-gfc-forward.conf")
BBR_MODULE_DROPIN = Path("/etc/modules-load.d/gfc-bbr.conf")

SYSCTL_WANT = """net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
"""


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _sysctl_get(key: str) -> str:
    r = _run(["sysctl", "-n", key])
    return (r.stdout or "").strip()


def _bbr_available() -> bool:
    avail = _sysctl_get("net.ipv4.tcp_available_congestion_control")
    return "bbr" in avail.split()


def _ensure_bbr_module() -> None:
    BBR_MODULE_DROPIN.parent.mkdir(parents=True, exist_ok=True)
    want = "tcp_bbr\n"
    try:
        cur = BBR_MODULE_DROPIN.read_text(encoding="utf-8")
    except OSError:
        cur = ""
    if cur.strip() != want.strip():
        BBR_MODULE_DROPIN.write_text(want, encoding="utf-8")
    _run(["modprobe", "tcp_bbr"])


def ensure_network_tuning() -> str:
    """IPv4 forwarding + TCP BBR (idempotent; safe on every agent start / apply)."""
    SYSCTL_DROPIN.parent.mkdir(parents=True, exist_ok=True)
    try:
        cur = SYSCTL_DROPIN.read_text(encoding="utf-8")
    except OSError:
        cur = ""
    if cur.strip() != SYSCTL_WANT.strip():
        SYSCTL_DROPIN.write_text(SYSCTL_WANT, encoding="utf-8")

    parts: list[str] = []

    _run(["sysctl", "-w", "net.ipv4.ip_forward=1"])
    _run(["sysctl", "-p", str(SYSCTL_DROPIN)])
    parts.append(f"ip_forward={_sysctl_get('net.ipv4.ip_forward') or '?'}")

    if _bbr_available():
        _ensure_bbr_module()
        _run(["sysctl", "-w", "net.core.default_qdisc=fq"])
        _run(["sysctl", "-w", "net.ipv4.tcp_congestion_control=bbr"])
        cc = _sysctl_get("net.ipv4.tcp_congestion_control")
        qdisc = _sysctl_get("net.core.default_qdisc")
        parts.append(f"tcp_cc={cc or '?'}")
        parts.append(f"qdisc={qdisc or '?'}")
    else:
        parts.append("tcp_cc=bbr_unavailable")

    return "; ".join(parts)


def ensure_ip_forward() -> str:
    """Backward-compatible alias."""
    return ensure_network_tuning()
