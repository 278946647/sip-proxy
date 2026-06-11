from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from dataclasses import dataclass


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hash_token(token: str, salt: str) -> str:
    # Deterministic hash for DB lookup (salted).
    return _sha256_hex((salt + ":" + token).encode("utf-8"))


def new_token(prefix: str = "node") -> str:
    raw = secrets.token_bytes(32)
    return f"{prefix}_" + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


@dataclass(frozen=True)
class TokenSecrets:
    salt: str


def load_token_secrets() -> TokenSecrets:
    # Single instance secret; for MVP store in env. In prod move to KMS/secret manager.
    salt = os.getenv("GFC_TOKEN_SALT") or "dev-salt-change-me"
    return TokenSecrets(salt=salt)


def constant_time_equal(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


_auth_secret_memo: str | None = None


def invalidate_auth_secret_cache() -> None:
    global _auth_secret_memo
    _auth_secret_memo = None


def _auth_secret() -> str:
    global _auth_secret_memo
    if _auth_secret_memo is not None:
        return _auth_secret_memo
    try:
        from .platform_secrets import get_auth_secret

        _auth_secret_memo = get_auth_secret()
        return _auth_secret_memo
    except ImportError:
        pass
    _auth_secret_memo = (
        os.getenv("GFC_AUTH_SECRET") or os.getenv("GFC_TOKEN_SALT") or "dev-auth-secret-change-me"
    )
    return _auth_secret_memo


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), 120_000
    ).hex()
    return f"pbkdf2_sha256${salt}${digest}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored or not password:
        return False
    try:
        algo, salt, digest = stored.split("$", 2)
        if algo != "pbkdf2_sha256":
            return False
        check = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt.encode("utf-8"), 120_000
        ).hex()
        return hmac.compare_digest(check, digest)
    except ValueError:
        return False


def create_access_token(user_id: int, username: str, *, ttl_seconds: int = 7 * 86400) -> str:
    payload = {
        "uid": user_id,
        "sub": username,
        "exp": int(time.time()) + ttl_seconds,
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    sig = hmac.new(_auth_secret().encode("utf-8"), raw, hashlib.sha256).hexdigest()
    return (
        base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
        + "."
        + sig
    )


def decode_access_token(token: str) -> dict | None:
    try:
        body_b64, sig = token.rsplit(".", 1)
        pad = "=" * (-len(body_b64) % 4)
        raw = base64.urlsafe_b64decode(body_b64 + pad)
        expected = hmac.new(_auth_secret().encode("utf-8"), raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, sig):
            return None
        payload = json.loads(raw.decode("utf-8"))
        if int(payload.get("exp") or 0) < int(time.time()):
            return None
        return payload
    except (ValueError, json.JSONDecodeError, OSError):
        return None

