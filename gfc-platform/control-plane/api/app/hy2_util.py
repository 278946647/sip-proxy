"""Hysteria2 helpers for forward-node ingress (P0 dual-transport)."""
from __future__ import annotations

import datetime as dt
import json
import secrets
from typing import Any

HY2_DEFAULT_PORT = 18443
HY2_DEFAULT_SNI = "www.cloudflare.com"
HY2_DEFAULT_MASQUERADE = "https://www.cloudflare.com/"
HY2_BRUTAL_RATIO = 0.93

LIVE_MODE_STANDARD = "standard"
LIVE_MODE_ALL_HY2 = "live_all_hy2"
LIVE_MODE_CATALOG = "live_catalog"  # P1 — accepted in schema, not routed yet

LIVE_MODES = frozenset({LIVE_MODE_STANDARD, LIVE_MODE_ALL_HY2, LIVE_MODE_CATALOG})


def normalize_live_mode(raw: str | None) -> str:
    mode = (raw or LIVE_MODE_STANDARD).strip().lower()
    if mode not in LIVE_MODES:
        return LIVE_MODE_STANDARD
    return mode


def brutal_mbps(bandwidth_mbps: int | float | None, *, enabled: bool = True) -> int:
    """When Brutal is on, default bandwidth = floor(line_mbps * 93%), min 1."""
    if not enabled:
        return 0
    try:
        mbps = float(bandwidth_mbps or 0)
    except (TypeError, ValueError):
        mbps = 0
    return max(1, int(mbps * HY2_BRUTAL_RATIO))


def generate_hy2_password() -> str:
    return secrets.token_urlsafe(24)


def _generate_self_signed_tls(cn: str) -> tuple[str, str]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=3650))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(cn)]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode("ascii")
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("ascii")
    return cert_pem, key_pem


def default_hy2_config() -> dict[str, Any]:
    cert_pem, key_pem = _generate_self_signed_tls(HY2_DEFAULT_SNI)
    return {
        "enabled": True,
        "listenPort": HY2_DEFAULT_PORT,
        "serverName": HY2_DEFAULT_SNI,
        "masquerade": HY2_DEFAULT_MASQUERADE,
        "certificate": cert_pem,
        "key": key_pem,
        "salamanderEnabled": False,
        "salamanderPassword": "",
    }


def ensure_node_hy2_config(node_hy2_json: str | None) -> dict[str, Any]:
    if node_hy2_json:
        try:
            cfg = json.loads(node_hy2_json)
            if (
                isinstance(cfg, dict)
                and cfg.get("certificate")
                and cfg.get("key")
                and int(cfg.get("listenPort") or 0) > 0
            ):
                out = dict(cfg)
                out.setdefault("enabled", True)
                out.setdefault("serverName", HY2_DEFAULT_SNI)
                out.setdefault("masquerade", HY2_DEFAULT_MASQUERADE)
                out.setdefault("salamanderEnabled", False)
                out["listenPort"] = int(out.get("listenPort") or HY2_DEFAULT_PORT)
                return out
        except (json.JSONDecodeError, TypeError, ValueError):
            pass
    return default_hy2_config()


def ensure_line_hy2_password(current: str | None) -> str:
    pw = (current or "").strip()
    if pw:
        return pw
    return generate_hy2_password()
