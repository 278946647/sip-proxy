from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import PlatformSetting

SMTP_KEY = "smtp"

_cached: dict[str, Any] | None = None


@dataclass(frozen=True)
class SmtpConfig:
    host: str
    port: int
    username: str | None
    password: str | None
    mail_from: str
    mail_to: str
    starttls: bool


def _from_env() -> SmtpConfig | None:
    host = os.getenv("GFC_SMTP_HOST")
    if not host:
        return None
    mail_to = os.getenv("GFC_SMTP_TO")
    if not mail_to:
        return None
    return SmtpConfig(
        host=host,
        port=int(os.getenv("GFC_SMTP_PORT") or "25"),
        username=os.getenv("GFC_SMTP_USER") or None,
        password=os.getenv("GFC_SMTP_PASS") or None,
        mail_from=os.getenv("GFC_SMTP_FROM") or "gfc@localhost",
        mail_to=mail_to,
        starttls=os.getenv("GFC_SMTP_STARTTLS") == "1",
    )


def _dict_to_config(data: dict[str, Any]) -> SmtpConfig | None:
    host = (data.get("host") or "").strip()
    mail_to = (data.get("mail_to") or data.get("mailTo") or "").strip()
    if not host or not mail_to:
        return None
    return SmtpConfig(
        host=host,
        port=int(data.get("port") or 25),
        username=(data.get("username") or "").strip() or None,
        password=data.get("password") or None,
        mail_from=(data.get("mail_from") or data.get("mailFrom") or "gfc@localhost").strip(),
        mail_to=mail_to,
        starttls=bool(data.get("starttls")),
    )


def get_smtp_config() -> SmtpConfig | None:
    global _cached
    if _cached:
        cfg = _dict_to_config(_cached)
        if cfg:
            return cfg
    return _from_env()


def set_smtp_cache(data: dict[str, Any] | None) -> None:
    global _cached
    _cached = data


async def load_smtp_settings(session: AsyncSession) -> dict[str, Any] | None:
    row = await session.get(PlatformSetting, SMTP_KEY)
    if not row:
        set_smtp_cache(None)
        return None
    try:
        data = json.loads(row.value_json)
    except json.JSONDecodeError:
        set_smtp_cache(None)
        return None
    if isinstance(data, dict):
        set_smtp_cache(data)
        return data
    set_smtp_cache(None)
    return None


async def save_smtp_settings(session: AsyncSession, data: dict[str, Any]) -> None:
    row = await session.get(PlatformSetting, SMTP_KEY)
    payload = json.dumps(data, ensure_ascii=False)
    if row:
        row.value_json = payload
        session.add(row)
    else:
        session.add(PlatformSetting(key=SMTP_KEY, value_json=payload))
    set_smtp_cache(data)


def smtp_to_public(data: dict[str, Any] | None) -> dict[str, Any]:
    if not data:
        env = _from_env()
        if not env:
            return {"configured": False, "source": "none"}
        return {
            "configured": True,
            "source": "env",
            "host": env.host,
            "port": env.port,
            "username": env.username,
            "passwordSet": bool(env.password),
            "mailFrom": env.mail_from,
            "mailTo": env.mail_to,
            "starttls": env.starttls,
        }
    return {
        "configured": True,
        "source": "db",
        "host": data.get("host"),
        "port": data.get("port", 25),
        "username": data.get("username"),
        "passwordSet": bool(data.get("password")),
        "mailFrom": data.get("mail_from") or data.get("mailFrom"),
        "mailTo": data.get("mail_to") or data.get("mailTo"),
        "starttls": bool(data.get("starttls")),
    }
