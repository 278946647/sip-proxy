"""HTTP reverse proxy to client LuCI / flash via local reverse HTTP port."""
from __future__ import annotations

import datetime as dt
import logging
import re
from urllib.parse import parse_qs, urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import ClientDevice, PlatformUser
from .reverse_ssh import session_active, tunnel_ready
from .security import decode_access_token
from .settings import settings
from .timeutil import utc_now

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/remote", tags=["remote"])

_SKIP_RESP_HEADERS = frozenset({
    "transfer-encoding",
    "connection",
    "content-encoding",
    "content-length",
})


async def _resolve_user(
    request: Request,
    session: AsyncSession,
    token: str | None = None,
    device_id: int | None = None,
) -> PlatformUser:
    bearer = _extract_bearer(request, token, device_id)
    payload = decode_access_token(bearer) if bearer else None
    if not payload:
        raise HTTPException(401, "not authenticated")
    row = await session.get(PlatformUser, _token_user_id(payload))
    if not row or not row.is_active:
        raise HTTPException(401, "user disabled or missing")
    return row


def _remote_auth_cookie_name(device_id: int) -> str:
    return f"gfc_remote_{device_id}"


def _extract_bearer(
    request: Request,
    token: str | None,
    device_id: int | None,
) -> str:
    bearer = (token or "").strip()
    if not bearer and device_id is not None:
        bearer = (request.cookies.get(_remote_auth_cookie_name(device_id)) or "").strip()
    if not bearer:
        auth = request.headers.get("authorization") or ""
        if auth.lower().startswith("bearer "):
            bearer = auth.split(" ", 1)[1].strip()
    return bearer


def _token_user_id(payload: dict) -> int:
    try:
        return int(payload.get("uid") or 0)
    except (TypeError, ValueError):
        return 0


async def _device_with_session(
    device_id: int,
    session: AsyncSession,
    request: Request,
    token: str | None = None,
) -> ClientDevice:
    await _resolve_user(request, session, token, device_id)
    device = await session.get(ClientDevice, device_id)
    if not device:
        raise HTTPException(404, "device not found")
    if not device.reverse_http_port:
        raise HTTPException(400, "reverse http port not allocated")
    if not session_active(device):
        raise HTTPException(403, "reverse ssh session not active")
    device.reverse_ssh_session_expires_at = utc_now() + dt.timedelta(
        seconds=settings.reverse_ssh_session_ttl_seconds
    )
    session.add(device)
    await session.commit()
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
    try:
        device = await _device_with_session(device_id, session, request, token)
        upstream = f"http://127.0.0.1:{device.reverse_http_port}/cgi-bin/luci/{path}"
        return await _proxy(request, upstream, device_id, token)
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("proxy_luci failed device=%s path=%s", device_id, path)
        raise HTTPException(500, f"luci proxy failed: {exc}") from exc


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
    return await _proxy(request, upstream, device_id, token)


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
    return await _proxy(request, upstream, device_id, token)


@router.api_route("/{device_id}/cgi-bin/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"])
async def proxy_cgi(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    upstream = f"http://127.0.0.1:{device.reverse_http_port}/cgi-bin/{path}"
    return await _proxy(request, upstream, device_id, token)


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
    return await _proxy(request, upstream, device_id, token)


async def _proxy(
    request: Request,
    upstream: str,
    device_id: int,
    token: str | None = None,
) -> Response:
    query = _upstream_query(request)
    if query:
        upstream = f"{upstream}?{query}"
    headers = _upstream_headers(request, device_id)
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=30.0, follow_redirects=False) as client:
            resp = await client.request(
                request.method,
                upstream,
                headers=headers,
                content=body if body else None,
            )
        out_headers = _response_headers(resp, device_id)
        content = resp.content
        ctype = ""
        for key, value in out_headers:
            if key.lower() == "content-type":
                ctype = value.lower()
                break
        if content and _should_rewrite_body(ctype):
            content = _rewrite_body_paths(content, device_id)
        response = _build_response(content, resp.status_code, out_headers)
        auth_token = _extract_bearer(request, token, device_id)
        if auth_token:
            _attach_remote_auth_cookie(response, device_id, auth_token)
        return response
    except HTTPException:
        raise
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"upstream unreachable: {exc}") from exc
    except Exception as exc:
        logger.exception("remote proxy failed device=%s upstream=%s", device_id, upstream)
        raise HTTPException(500, f"remote proxy error: {exc}") from exc


def _build_response(
    content: bytes,
    status_code: int,
    header_pairs: list[tuple[str, str]],
) -> Response:
    """Apply response headers (supports multiple Set-Cookie values)."""
    response = Response(content=content, status_code=status_code)
    for key, value in header_pairs:
        if key.lower() == "set-cookie":
            response.headers.append(key, value)
        else:
            response.headers[key] = value
    return response


def _attach_remote_auth_cookie(response: Response, device_id: int, token: str) -> None:
    """Persist platform JWT for follow-up luci-static/cgi-bin requests (no ?token=)."""
    response.headers.append(
        "set-cookie",
        _safe_header_value(
            f"{_remote_auth_cookie_name(device_id)}={token}; "
            f"Path=/remote/{device_id}/; HttpOnly; SameSite=Lax; Max-Age=86400"
        ),
    )


def _upstream_headers(request: Request, device_id: int) -> dict[str, str]:
    headers: dict[str, str] = {}
    for key, value in request.headers.items():
        kl = key.lower()
        if kl in {"host", "content-length", "connection", "cookie"}:
            continue
        headers[key] = value
    cookie = _upstream_cookie(request, device_id)
    if cookie:
        headers["cookie"] = cookie
    return headers


def _upstream_cookie(request: Request, device_id: int) -> str:
    raw = request.headers.get("cookie") or ""
    if not raw:
        return ""
    our_name = _remote_auth_cookie_name(device_id)
    kept: list[str] = []
    for item in raw.split(";"):
        item = item.strip()
        if not item:
            continue
        name = item.split("=", 1)[0].strip()
        if name == our_name:
            continue
        kept.append(item)
    return "; ".join(kept)


def _response_headers(resp: httpx.Response, device_id: int) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for key, value in resp.headers.multi_items():
        kl = key.lower()
        if kl in _SKIP_RESP_HEADERS:
            continue
        if kl == "set-cookie":
            out.append((key, _safe_header_value(_rewrite_set_cookie(value, device_id))))
            continue
        if kl == "location":
            value = _rewrite_remote_location(value, device_id)
        out.append((key, _safe_header_value(value)))
    return out


def _safe_header_value(value: str) -> str:
    """Starlette requires header values to be latin-1 encodable."""
    if not value:
        return value
    try:
        value.encode("latin-1")
        return value
    except UnicodeEncodeError:
        return value.encode("latin-1", errors="replace").decode("latin-1")


def _upstream_query(request: Request) -> str:
    """Forward client query string but drop platform auth token."""
    raw = str(request.url.query or "")
    if not raw:
        return ""
    params = parse_qs(raw, keep_blank_values=True)
    params.pop("token", None)
    if not params:
        return ""
    return urlencode(params, doseq=True)


def _rewrite_set_cookie(value: str, device_id: int) -> str:
    """Scope LuCI session cookies under /remote/{device_id}/ so the browser sends them."""
    prefix = f"/remote/{device_id}"

    def repl(match: re.Match[str]) -> str:
        path = match.group(1)
        if path.startswith(prefix):
            return match.group(0)
        if path == "/":
            return f"Path={prefix}/"
        return f"Path={prefix}{path}"

    return re.sub(r"Path=(/[^;]*)", repl, value, flags=re.IGNORECASE)


def _rewrite_remote_location(location: str, device_id: int) -> str:
    """Rewrite LuCI redirects so they stay under /remote/{device_id}/."""
    loc = (location or "").strip()
    if not loc:
        return loc
    prefix = f"/remote/{device_id}"
    if loc.startswith(prefix):
        return loc
    if loc.startswith("/cgi-bin/"):
        return f"{prefix}{loc}"
    if loc.startswith("/luci-static/"):
        return f"{prefix}{loc}"
    if loc.startswith("/gfc/"):
        return f"{prefix}{loc}"
    if loc.startswith("/cgi-bin/luci/"):
        path = loc[len("/cgi-bin/luci/") :]
        return f"{prefix}/luci/{path}"
    return loc


_PATH_SEGMENTS = ("cgi-bin", "luci-static", "gfc")


def _should_rewrite_body(ctype: str) -> bool:
    return any(
        t in ctype
        for t in (
            "text/html",
            "text/css",
            "javascript",
            "application/json",
            "text/plain",
        )
    )


def _rewrite_body_paths(content: bytes, device_id: int) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    try:
        return _rewrite_text_paths(text, device_id).encode("utf-8")
    except UnicodeEncodeError:
        return content


def _rewrite_text_paths(text: str, device_id: int) -> str:
    """Rewrite root-relative LuCI paths in HTML/JS/CSS so XHR and assets stay proxied."""
    prefix = f"/remote/{device_id}"
    double = f"{prefix}{prefix}"
    while double in text:
        text = text.replace(double, prefix)

    esc_prefix = "\\/remote\\/" + str(device_id)
    for seg in _PATH_SEGMENTS:
        for quote in ('"', "'", "`"):
            text = text.replace(f"{quote}/{seg}/", f"{quote}{prefix}/{seg}/")
            text = text.replace(f'{quote}/{seg}"', f'{quote}{prefix}/{seg}"')
            text = text.replace(f"{quote}/{seg}'", f"{quote}{prefix}/{seg}'")
        text = text.replace(f"url(/{seg}/", f"url({prefix}/{seg}/")
        text = text.replace(f"\\/{seg}\\/", f"{esc_prefix}\\/{seg}\\/")

    # LuCI base path without trailing segment, e.g. "/cgi-bin/luci"
    text = text.replace('"/cgi-bin/luci"', f'"{prefix}/cgi-bin/luci"')
    text = text.replace("'/cgi-bin/luci'", f"'{prefix}/cgi-bin/luci'")
    text = text.replace("\\/cgi-bin\\/luci", f"{esc_prefix}\\/cgi-bin\\/luci")
    return text
