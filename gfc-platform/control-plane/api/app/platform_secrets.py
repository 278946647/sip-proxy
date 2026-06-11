from __future__ import annotations

import json
import secrets
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import PlatformSetting, PlatformUser
from .security import hash_password, invalidate_auth_secret_cache
from .settings import settings

SECURITY_KEY = "security"

_cache: dict[str, Any] = {}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _generate_bootstrap() -> str:
    return f"gfc-{secrets.token_urlsafe(18)}"


def _generate_auth_secret() -> str:
    return secrets.token_urlsafe(48)


def _generate_admin_password() -> str:
    return secrets.token_urlsafe(12)


def _is_default_bootstrap(value: str) -> bool:
    return value.strip() in ("", "demo-bootstrap")


def _is_default_auth_secret(value: str) -> bool:
    return value.strip() in (
        "",
        "dev-auth-secret-change-me",
        "change-me-in-production",
    )


def _is_default_admin_password_env() -> bool:
    return settings.admin_default_password in ("", "admin123")


def get_bootstrap_tokens() -> set[str]:
    raw = _cache.get("bootstrap_tokens") or settings.bootstrap_tokens
    return {t.strip() for t in str(raw).split(",") if t.strip()}


def get_primary_bootstrap_token() -> str:
    tokens = sorted(get_bootstrap_tokens())
    return tokens[0] if tokens else ""


def get_auth_secret() -> str:
    cached = (_cache.get("auth_secret") or "").strip()
    if cached:
        return cached
    env = (settings.auth_secret or "").strip()
    if env and not _is_default_auth_secret(env):
        return env
    return "dev-auth-secret-change-me"


def password_change_required(data: dict[str, Any] | None = None) -> bool:
    src = data if data is not None else _cache
    return bool((src.get("generated_admin_password") or "").strip())


def security_to_public(data: dict[str, Any]) -> dict[str, Any]:
    return {
        "bootstrap_tokens": data.get("bootstrap_tokens") or get_primary_bootstrap_token(),
        "auth_secret_configured": bool((data.get("auth_secret") or get_auth_secret()).strip()),
        "generated_admin_password": data.get("generated_admin_password"),
        "password_change_required": password_change_required(data),
        "source": "database" if data.get("persisted") else "env",
        "syncs_to_nodes": ["bootstrap_tokens"],
        "updated_at": data.get("updated_at"),
    }


async def load_security_settings(session: AsyncSession) -> dict[str, Any]:
    row = await session.get(PlatformSetting, SECURITY_KEY)
    if not row:
        return {}
    try:
        data = json.loads(row.value_json)
        if isinstance(data, dict):
            data["persisted"] = True
            _cache.update(data)
            return data
    except json.JSONDecodeError:
        pass
    return {}


async def ensure_platform_secrets(session: AsyncSession) -> dict[str, Any]:
    """First boot: generate secrets if missing; persist to DB."""
    data = await load_security_settings(session)
    if data.get("persisted"):
        return data

    bootstrap = settings.bootstrap_tokens.strip()
    if _is_default_bootstrap(bootstrap):
        bootstrap = _generate_bootstrap()

    auth_secret = settings.auth_secret.strip()
    if _is_default_auth_secret(auth_secret):
        auth_secret = _generate_auth_secret()

    generated_admin_password: str | None = None
    if _is_default_admin_password_env():
        generated_admin_password = _generate_admin_password()

    data = {
        "bootstrap_tokens": bootstrap,
        "auth_secret": auth_secret,
        "generated_admin_password": generated_admin_password,
        "updated_at": _now_iso(),
        "persisted": True,
    }
    session.add(
        PlatformSetting(
            key=SECURITY_KEY,
            value_json=json.dumps(
                {k: v for k, v in data.items() if k != "persisted"},
                ensure_ascii=False,
            ),
        )
    )
    _cache.update(data)
    invalidate_auth_secret_cache()

    if generated_admin_password:
        admin = (
            await session.execute(select(PlatformUser).where(PlatformUser.username == "admin"))
        ).scalar_one_or_none()
        if admin:
            admin.password_hash = hash_password(generated_admin_password)
            session.add(admin)

    await session.commit()
    print(
        f"[GFC] Security initialized. bootstrap_token={bootstrap}"
        + (
            f" initial_admin_password={generated_admin_password}"
            if generated_admin_password
            else ""
        )
        + " — 初始密码亦显示于 Web 登录页，登录后须强制修改。",
        flush=True,
    )
    return data


async def save_security_settings(
    session: AsyncSession,
    *,
    bootstrap_tokens: str | None = None,
    auth_secret: str | None = None,
    admin_password: str | None = None,
    clear_generated_password: bool = True,
) -> dict[str, Any]:
    data = await load_security_settings(session)
    if not data.get("persisted"):
        data = await ensure_platform_secrets(session)

    if bootstrap_tokens is not None:
        tokens = [t.strip() for t in bootstrap_tokens.split(",") if t.strip()]
        if not tokens:
            raise ValueError("bootstrap_tokens 不能为空")
        data["bootstrap_tokens"] = ",".join(tokens)

    if auth_secret is not None:
        secret = auth_secret.strip()
        if len(secret) < 16:
            raise ValueError("auth_secret 至少 16 个字符")
        data["auth_secret"] = secret
        invalidate_auth_secret_cache()

    if admin_password is not None:
        if len(admin_password) < 8:
            raise ValueError("管理员密码至少 8 个字符")
        admin = (
            await session.execute(select(PlatformUser).where(PlatformUser.username == "admin"))
        ).scalar_one_or_none()
        if admin:
            admin.password_hash = hash_password(admin_password)
            session.add(admin)
        if clear_generated_password:
            data.pop("generated_admin_password", None)

    data["updated_at"] = _now_iso()
    payload = {k: v for k, v in data.items() if k != "persisted"}
    row = await session.get(PlatformSetting, SECURITY_KEY)
    if row:
        row.value_json = json.dumps(payload, ensure_ascii=False)
        row.updated_at = datetime.now(timezone.utc)
        session.add(row)
    else:
        session.add(PlatformSetting(key=SECURITY_KEY, value_json=json.dumps(payload)))

    _cache.update({**payload, "persisted": True})
    return data
