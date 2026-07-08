"""HTTP reverse proxy to client LuCI / flash via local reverse HTTP port."""
from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import ClientDevice, PlatformUser
from .reverse_ssh import session_active, tunnel_ready
from .security import decode_access_token

router = APIRouter(prefix="/remote", tags=["remote"])


async def _resolve_user(
    request: Request,
    session: AsyncSession,
    token: str | None = None,
) -> PlatformUser:
    bearer = (token or "").strip()
    if not bearer:
        auth = request.headers.get("authorization") or ""
        if auth.lower().startswith("bearer "):
            bearer = auth.split(" ", 1)[1].strip()
    payload = decode_access_token(bearer) if bearer else None
    if not payload:
        raise HTTPException(401, "not authenticated")
    row = await session.get(PlatformUser, int(payload.get("uid") or 0))
    if not row or not row.is_active:
        raise HTTPException(401, "user disabled or missing")
    return row


async def _device_with_session(
    device_id: int,
    session: AsyncSession,
    request: Request,
    token: str | None = None,
) -> ClientDevice:
    await _resolve_user(request, session, token)
    device = await session.get(ClientDevice, device_id)
    if not device:
        raise HTTPException(404, "device not found")
    if not device.reverse_http_port:
        raise HTTPException(400, "reverse http port not allocated")
    if not session_active(device):
        raise HTTPException(403, "reverse ssh session not active")
    if not tunnel_ready(device):
        raise HTTPException(503, "reverse tunnel not ready")
    return device


@router.api_route("/{device_id}/luci/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"])
async def proxy_luci(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/cgi-bin/luci/{path}"
    return await _proxy(request, upstream, token)


@router.api_route("/{device_id}/flash/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"])
async def proxy_flash(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    if not path:
        path = "gfc/activate.html"
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/{path}"
    return await _proxy(request, upstream, token)


@router.get("/{device_id}/flash")
async def proxy_flash_root(
    device_id: int,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    return await proxy_flash(device_id, "gfc/activate.html", request, session, token)


@router.api_route("/{device_id}/luci-static/{path:path}", methods=["GET", "HEAD"])
async def proxy_luci_static(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/luci-static/{path}"
    return await _proxy(request, upstream, token)


@router.api_route("/{device_id}/cgi-bin/{path:path}", methods=["GET", "POST", "HEAD"])
async def proxy_cgi(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/cgi-bin/{path}"
    return await _proxy(request, upstream, token)


@router.api_route("/{device_id}/gfc/{path:path}", methods=["GET", "HEAD"])
async def proxy_gfc_static(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/gfc/{path}"
    return await _proxy(request, upstream, token)


async def _proxy(request: Request, upstream: str, token: str | None = None) -> Response:
    query = str(request.url.query or "")
    if token and "token=" not in query:
        query = f"{query}&token={token}" if query else f"token={token}"
    if query:
        upstream = f"{upstream}?{query}"
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in {"host", "content-length", "connection"}
    }
    body = await request.body()
    async with httpx.AsyncClient(timeout=30.0, follow_redirects=False) as client:
        resp = await client.request(
            request.method,
            upstream,
            headers=headers,
            content=body if body else None,
        )
    out_headers = {
        k: v
        for k, v in resp.headers.items()
        if k.lower() not in {"transfer-encoding", "connection", "content-encoding"}
    }
    return Response(content=resp.content, status_code=resp.status_code, headers=out_headers)
