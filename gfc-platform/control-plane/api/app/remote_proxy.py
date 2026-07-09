"""HTTP reverse proxy to client LuCI / flash via local reverse HTTP port."""
from __future__ import annotations

import datetime as dt
import logging
import re
from urllib.parse import parse_qs, unquote, urlencode

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .models import ClientDevice, PlatformUser
from .reverse_ssh import session_active, tunnel_ready
from .permissions import can_remote_access
from .security import decode_access_token
from .settings import settings
from .timeutil import utc_now

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/remote", tags=["remote"])
root_shim_router = APIRouter(tags=["remote-root-shim"])

_LUCI_PROXY_METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

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
    if not can_remote_access(row.role):
        raise HTTPException(403, "permission denied")
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
    if not bearer:
        referer = request.headers.get("referer") or ""
        m = re.search(r"[?&]token=([^&]+)", referer)
        if m:
            bearer = unquote(m.group(1)).strip()
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


@router.api_route(
    "/{device_id}/remote/{dup_id}/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"],
)
async def proxy_dup_prefix(
    device_id: int,
    dup_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    """Handle double /remote/{id}/remote/{id}/... from mixed rewrite + L.url()."""
    if dup_id != device_id:
        raise HTTPException(404, "device path mismatch")
    if path.startswith("cgi-bin/"):
        return await proxy_cgi(device_id, path, request, session, token)
    if path.startswith("luci-static/"):
        return await proxy_luci_static(device_id, path[len("luci-static/") :], request, session, token)
    if path.startswith("luci/"):
        return await proxy_luci(device_id, path[len("luci/") :], request, session, token)
    raise HTTPException(404, "unknown remote path")


@router.api_route("/{device_id}/luci/{path:path}", methods=_LUCI_PROXY_METHODS)
async def proxy_luci(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    try:
        device = await _device_with_session(device_id, session, request, token)
        path = _normalize_luci_path(path)
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


@router.api_route("/{device_id}/cgi-bin/{path:path}", methods=_LUCI_PROXY_METHODS)
async def proxy_cgi(
    device_id: int,
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device = await _device_with_session(device_id, session, request, token)
    path = _normalize_cgi_path(path)
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
        elif content and _should_rewrite_css(ctype):
            content = _rewrite_css_paths(content, device_id)
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
            f"Path=/; HttpOnly; SameSite=Lax; Max-Age=86400"
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
        # Broader than /cgi-bin/luci/ so subpaths like .../admin/ubus receive sysauth.
        scoped = f"{prefix}{path}"
        if path.startswith("/cgi-bin/"):
            scoped = f"{prefix}/"
        return f"Path={scoped}"

    return re.sub(r"Path=(/[^;]*)", repl, value, flags=re.IGNORECASE)


def _rewrite_remote_location(location: str, device_id: int) -> str:
    """Rewrite LuCI redirects so they stay under /remote/{device_id}/."""
    loc = (location or "").strip()
    if not loc:
        return loc
    prefix = f"/remote/{device_id}"
    loc = _collapse_remote_prefix(loc, device_id)
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


def _collapse_remote_prefix(path: str, device_id: int) -> str:
    prefix = f"/remote/{device_id}"
    double = f"{prefix}{prefix}"
    while double in path:
        path = path.replace(double, prefix)
    return path


def _should_rewrite_body(ctype: str) -> bool:
    # Only rewrite HTML shell — JS/CSS keep originals; LuCI base URL is injected in HTML.
    return "text/html" in ctype


def _should_rewrite_css(ctype: str) -> bool:
    return "text/css" in ctype


def _rewrite_body_paths(content: bytes, device_id: int) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    try:
        text = _collapse_remote_prefix(text, device_id)
        text = _rewrite_html_asset_paths(text, device_id)
        if "<html" in text.lower():
            text = _inject_luci_remote_base(text, device_id)
        return text.encode("utf-8")
    except UnicodeEncodeError:
        return content


def _rewrite_css_paths(content: bytes, device_id: int) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    prefix = f"/remote/{device_id}"
    text = text.replace("url(/luci-static/", f"url({prefix}/luci-static/")
    return text.encode("utf-8")


def _normalize_luci_path(path: str) -> str:
    """LuCI RPC must hit admin/ubus, not a page-relative .../status/ubus."""
    raw = (path or "").strip().lstrip("/")
    if raw == "ubus" or (raw.endswith("/ubus") and raw != "admin/ubus"):
        return "admin/ubus"
    return raw


def _normalize_cgi_path(path: str) -> str:
    raw = (path or "").strip().lstrip("/")
    if raw.endswith("/ubus") and raw not in {"luci/admin/ubus", "admin/ubus"}:
        return "luci/admin/ubus"
    return raw


def _parse_remote_device_id(referer: str) -> int | None:
    m = re.search(r"/remote/(\d+)(?:/|$)", referer or "")
    if m:
        return int(m.group(1))
    return None


def _device_id_from_request(request: Request) -> int:
    device_id = _parse_remote_device_id(request.headers.get("referer", ""))
    if device_id is not None:
        return device_id
    for key in request.cookies:
        if key.startswith("gfc_remote_"):
            suffix = key[len("gfc_remote_") :]
            if suffix.isdigit():
                return int(suffix)
    raise HTTPException(404, "missing remote device context")


@root_shim_router.api_route("/cgi-bin/{path:path}", methods=_LUCI_PROXY_METHODS)
async def shim_root_cgi(
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    """LuCI sometimes calls /cgi-bin/... without /remote/{id}/ — resolve device from Referer."""
    device_id = _device_id_from_request(request)
    return await proxy_cgi(device_id, path, request, session, token)


@root_shim_router.api_route("/luci-static/{path:path}", methods=["GET", "HEAD", "OPTIONS"])
async def shim_root_luci_static(
    path: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    token: str | None = Query(default=None),
) -> Response:
    device_id = _device_id_from_request(request)
    return await proxy_luci_static(device_id, path, request, session, token)


def _inject_luci_remote_base(html: str, device_id: int) -> str:
    """Pin LuCI base paths under /remote/{id}; patch L.url to avoid double prefix."""
    marker = f'data-gfc-remote="{device_id}"'
    if marker in html:
        return html
    script = f"""<script {marker}>(function(){{
var DID={device_id};
var P="/remote/"+DID;
var BASE=P+"/cgi-bin/luci";
var STATIC=P+"/luci-static";
var TKEY="gfc_remote_token_"+DID;
function dedupe(u){{
 if(typeof u!=="string")return u;
 var prefix=P+"/";
 while(u.indexOf(prefix+prefix)===0)u=prefix+u.slice(prefix.length);
 var dup=P+"/remote/"+DID+"/";
 while(u.indexOf(dup)===0)u=P+"/"+u.slice(dup.length);
 return u;
}}
function fixPath(path){{
 if(typeof path!=="string")return path;
 path=dedupe(path);
 if(path.indexOf(P+"/")===0)return path;
 if(path.charAt(0)==="/"&&(path.indexOf("/cgi-bin/")===0||path.indexOf("/luci-static/")===0||path.indexOf("/gfc/")===0))
  return P+path;
 return path;
}}
function fixUrl(u){{
 if(typeof u!=="string")return u;
 if(u.indexOf("://")>0)try{{
  var pu=new URL(u);
  var np=fixPath(pu.pathname);
  if(np!==pu.pathname)return pu.origin+np+pu.search+pu.hash;
  return u;
 }}catch(e){{}}
 return fixPath(u);
}}
function authUrl(u){{
 if(typeof u!=="string")return false;
 return u.indexOf("/cgi-bin/")>=0||u.indexOf(P+"/")===0||u.indexOf("/luci-static/")>=0||u.indexOf("/gfc/")>=0;
}}
function loadToken(){{
 try{{
  var q=location.search.match(/[?&]token=([^&]+)/);
  if(q){{var t=decodeURIComponent(q[1]);sessionStorage.setItem(TKEY,t);return t;}}
  return sessionStorage.getItem(TKEY)||"";
 }}catch(e){{return "";}}
}}
var TOKEN=loadToken();
function patchTransport(){{
 if(window.__gfcRemoteTransport)return;
 var xo=XMLHttpRequest.prototype.open;
 var xs=XMLHttpRequest.prototype.send;
 XMLHttpRequest.prototype.open=function(){{
  if(arguments.length>1&&typeof arguments[1]==="string")
   arguments[1]=fixUrl(arguments[1]);
  this.__gfcAuth=TOKEN&&arguments.length>1&&authUrl(String(arguments[1]));
  return xo.apply(this,arguments);
 }};
 XMLHttpRequest.prototype.send=function(body){{
  if(this.__gfcAuth)try{{this.setRequestHeader("Authorization","Bearer "+TOKEN);}}catch(e){{}}
  return xs.call(this,body);
 }};
 if(window.fetch){{
  var of=window.fetch;
  window.fetch=function(input,init){{
   var url=typeof input==="string"?input:(input&&input.url)||"";
   url=fixUrl(url);
   if(typeof input==="string")input=url;
   else if(input&&input.url)input=new Request(url,input);
   if(TOKEN&&authUrl(url)){{
    init=init?Object.assign({{}},init):{{}};
    var h=new Headers(init.headers||{{}});
    if(!h.has("Authorization"))h.set("Authorization","Bearer "+TOKEN);
    init.headers=h;
   }}
   return of.call(this,input,init);
  }};
 }}
 window.__gfcRemoteTransport=true;
}}
function applyEnv(){{
 if(!window.L||!L.env)return;
 L.env.scriptname=BASE;
 var m=L.env.media||"";
 if(!m||m.indexOf(P)!==0){{
  if(m.indexOf("/luci-static")===0)L.env.media=STATIC+m.slice("/luci-static".length);
  else L.env.media=STATIC+"/resources";
 }}
}}
function patchUrl(){{
 if(!window.L||!L.prototype||L.prototype.__gfcRemote)return;
 var orig=L.prototype.url;
 if(typeof orig==="function"){{
  L.prototype.url=function(){{return fixUrl(orig.apply(this,arguments));}};
 }}
 if(typeof L.prototype.resource==="function"){{
  var or=L.prototype.resource;
  L.prototype.resource=function(){{return fixUrl(or.apply(this,arguments));}};
 }}
 L.prototype.__gfcRemote=true;
}}
function boot(){{patchTransport();applyEnv();patchUrl();}}
boot();
document.addEventListener("DOMContentLoaded",boot);
var n=0,t=setInterval(function(){{boot();if(++n>60)clearInterval(t);}},100);
}})();</script>"""
    lower = html.lower()
    head = lower.find("<head")
    if head < 0:
        return script + html
    close = html.find(">", head)
    if close < 0:
        return script + html
    return html[: close + 1] + script + html[close + 1 :]


def _rewrite_html_asset_paths(text: str, device_id: int) -> str:
    """Rewrite only HTML tag asset/link URLs — do not touch external .js files."""
    prefix = f"/remote/{device_id}"
    text = _collapse_remote_prefix(text, device_id)
    pattern = r'\b(src|href|action)=(["\'])/(luci-static|cgi-bin|gfc)/'
    text = re.sub(pattern, rf"\1=\2{prefix}/\3/", text)
    return text
