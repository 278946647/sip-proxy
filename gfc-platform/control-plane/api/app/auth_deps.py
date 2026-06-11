from __future__ import annotations

from fastapi import Depends, Header, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import PlatformUser
from .security import decode_access_token


async def get_current_user(
    authorization: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> PlatformUser:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="not authenticated")
    token = authorization.split(" ", 1)[1].strip()
    payload = decode_access_token(token)
    if not payload:
        raise HTTPException(status_code=401, detail="invalid or expired token")
    user_id = int(payload.get("uid") or 0)
    user = await session.get(PlatformUser, user_id)
    if not user or not user.is_active:
        raise HTTPException(status_code=401, detail="user disabled or missing")
    return user


async def require_admin(user: PlatformUser = Depends(get_current_user)) -> PlatformUser:
    if user.role != "admin":
        raise HTTPException(status_code=403, detail="admin required")
    return user
