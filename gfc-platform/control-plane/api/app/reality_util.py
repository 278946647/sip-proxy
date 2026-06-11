"""REALITY keypair helpers for forward-node ingress."""
from __future__ import annotations

import base64
import json
import secrets
import subprocess
from typing import Any


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _generate_via_singbox() -> tuple[str, str] | None:
    try:
        r = subprocess.run(
            ["sing-box", "generate", "reality-keypair"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    private_key = public_key = None
    for line in (r.stdout or "").splitlines():
        low = line.strip().lower()
        if low.startswith("privatekey:"):
            private_key = line.split(":", 1)[1].strip()
        elif low.startswith("publickey:"):
            public_key = line.split(":", 1)[1].strip()
    if private_key and public_key:
        return private_key, public_key
    return None


def _generate_via_cryptography() -> tuple[str, str]:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    private = X25519PrivateKey.generate()
    private_bytes = private.private_bytes_raw()
    public_bytes = private.public_key().public_bytes_raw()
    return _b64url(private_bytes), _b64url(public_bytes)


def generate_reality_keypair() -> tuple[str, str]:
    pair = _generate_via_singbox()
    if pair:
        return pair
    try:
        return _generate_via_cryptography()
    except ImportError:
        raise RuntimeError(
            "Install sing-box CLI or `pip install cryptography` to generate REALITY keys"
        )


def default_reality_config() -> dict[str, Any]:
    private_key, public_key = generate_reality_keypair()
    short_id = secrets.token_hex(4)
    return {
        "enabled": True,
        "listenPort": 443,
        "privateKey": private_key,
        "publicKey": public_key,
        "shortIds": [short_id],
        "serverNames": ["www.microsoft.com"],
        "dest": "www.microsoft.com:443",
    }


def ensure_node_reality_config(node_reality_json: str | None) -> dict[str, Any]:
    if node_reality_json:
        try:
            cfg = json.loads(node_reality_json)
            if isinstance(cfg, dict) and cfg.get("privateKey") and cfg.get("publicKey"):
                return cfg
        except json.JSONDecodeError:
            pass
    return default_reality_config()
