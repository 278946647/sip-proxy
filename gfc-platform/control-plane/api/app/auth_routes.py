from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .auth_deps import get_current_user
from .db import get_session
from .models import PlatformUser
from .platform_secrets import load_security_settings, password_change_required, save_security_settings
from .schemas import (
    ChangePasswordIn,
    InitialPasswordChangeIn,
    LoginIn,
    LoginOut,
    SetupHintOut,
    UserOut,
)
from .security import create_access_token, hash_password, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


async def _must_change_password(session: AsyncSession) -> bool:
    data = await load_security_settings(session)
    return password_change_required(data)


@router.get("/setup-hint", response_model=SetupHintOut)
async def setup_hint(session: AsyncSession = Depends(get_session)) -> SetupHintOut:
    """Public hint for first deploy — initial password shown until admin changes it."""
    data = await load_security_settings(session)
    pwd = (data.get("generated_admin_password") or "").strip() or None
    return SetupHintOut(
        username="admin",
        initial_password=pwd,
        password_change_required=bool(pwd),
    )


@router.post("/login", response_model=LoginOut)
async def login(body: LoginIn, session: AsyncSession = Depends(get_session)) -> LoginOut:
    stmt = select(PlatformUser).where(PlatformUser.username == body.username.strip())
    user = (await session.execute(stmt)).scalars().first()
    if not user or not user.is_active or not verify_password(body.password, user.password_hash):
        raise HTTPException(status_code=401, detail="invalid username or password")
    must_change = await _must_change_password(session)
    token = create_access_token(user.id, user.username)
    return LoginOut(
        token=token,
        user=UserOut(
            id=user.id,
            username=user.username,
            role=user.role,
            is_active=user.is_active,
            created_at=user.created_at,
        ),
        must_change_password=must_change,
    )


@router.post("/initial-password-change", response_model=LoginOut)
async def initial_password_change(
    body: InitialPasswordChangeIn,
    user: PlatformUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> LoginOut:
    if user.role != "admin":
        raise HTTPException(status_code=403, detail="admin required")
    if not await _must_change_password(session):
        raise HTTPException(status_code=400, detail="无需修改初始密码")
    if body.new_password != body.confirm_password:
        raise HTTPException(status_code=400, detail="两次输入的密码不一致")
    await save_security_settings(session, admin_password=body.new_password)
    await session.commit()
    token = create_access_token(user.id, user.username)
    return LoginOut(
        token=token,
        user=UserOut(
            id=user.id,
            username=user.username,
            role=user.role,
            is_active=user.is_active,
            created_at=user.created_at,
        ),
        must_change_password=False,
    )


@router.get("/me", response_model=UserOut)
async def me(user: PlatformUser = Depends(get_current_user)) -> UserOut:
    return UserOut(
        id=user.id,
        username=user.username,
        role=user.role,
        is_active=user.is_active,
        created_at=user.created_at,
    )


@router.post("/change-password")
async def change_password(
    body: ChangePasswordIn,
    user: PlatformUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> dict[str, bool]:
    if not verify_password(body.old_password, user.password_hash):
        raise HTTPException(status_code=400, detail="current password incorrect")
    if len(body.new_password) < 6:
        raise HTTPException(status_code=400, detail="new password must be at least 6 characters")
    user.password_hash = hash_password(body.new_password)
    session.add(user)
    await session.commit()
    return {"ok": True}


@router.post("/logout")
async def logout() -> dict[str, bool]:
    return {"ok": True}
