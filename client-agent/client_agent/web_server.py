from __future__ import annotations

import argparse
import json
import mimetypes
import os
import ssl
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .device_info import collect_device_info, list_network_interfaces, read_settings
from .network import network_status
from .web_actions import (
    LOG_FILES,
    SERVICE_UNITS,
    flash_line_code,
    restart_service,
    tail_log,
    update_settings,
)

STATUS_FILE = Path(os.environ.get("GFC_STATUS_FILE", "/var/lib/gfc-client/status.json"))
DEFAULT_WEB_ROOT = Path(os.environ.get("GFC_CLIENT_WEB_ROOT", "/opt/gfc-client/client-web"))
DEFAULT_WEB_PORT = int(os.environ.get("GFC_CLIENT_WEB_PORT", "80"))
FLASH_PORT = int(os.environ.get("GFC_CLIENT_FLASH_PORT", "81"))
HTTPS_PORT = int(os.environ.get("GFC_CLIENT_HTTPS_PORT", "443"))


def _json_response(handler: BaseHTTPRequestHandler, status: int, data: Any) -> None:
    body = json.dumps(data, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def _read_json_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("request body must be a JSON object")
    return data


def _load_status() -> dict[str, Any]:
    if STATUS_FILE.is_file():
        try:
            data = json.loads(STATUS_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except (OSError, json.JSONDecodeError):
            pass
    return {}


def _serve_static(handler: BaseHTTPRequestHandler, rel_path: str) -> None:
    web_root: Path = handler.server.web_root  # type: ignore[attr-defined]
    mode: str = handler.server.web_mode  # type: ignore[attr-defined]

    if rel_path in ("", "/"):
        rel_path = "flash.html" if mode == "flash" else "index.html"

    if mode == "flash":
        allowed = ("flash.html", "css/", "js/")
        if not (rel_path == "flash.html" or rel_path.startswith(allowed[1:])):
            handler.send_error(HTTPStatus.NOT_FOUND)
            return

    rel_path = rel_path.lstrip("/")
    if ".." in rel_path.split("/"):
        handler.send_error(HTTPStatus.FORBIDDEN)
        return
    fp = web_root / rel_path
    if not fp.is_file():
        handler.send_error(HTTPStatus.NOT_FOUND)
        return
    content = fp.read_bytes()
    ctype, _ = mimetypes.guess_type(str(fp))
    handler.send_response(HTTPStatus.OK)
    handler.send_header("Content-Type", ctype or "application/octet-stream")
    handler.send_header("Content-Length", str(len(content)))
    handler.end_headers()
    handler.wfile.write(content)


class ClientWebHandler(BaseHTTPRequestHandler):
    server_version = "GFCClientWeb/0.2"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    @property
    def _mode(self) -> str:
        return self.server.web_mode  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            if path == "/api/status":
                status = _load_status()
                device = collect_device_info(status.get("control_plane_url"))
                _json_response(
                    self,
                    HTTPStatus.OK,
                    {"device": device, "metrics": status, "network": network_status()},
                )
                return

            if path == "/api/device":
                status = _load_status()
                _json_response(
                    self,
                    HTTPStatus.OK,
                    collect_device_info(status.get("control_plane_url")),
                )
                return

            if path == "/api/network":
                _json_response(self, HTTPStatus.OK, network_status())
                return

            if self._mode == "flash":
                if path.startswith("/api/") and path != "/api/device":
                    _json_response(
                        self,
                        HTTPStatus.FORBIDDEN,
                        {"error": "刷码端口仅支持刷入线路码"},
                    )
                    return
                if path == "/api/device":
                    status = _load_status()
                    _json_response(
                        self,
                        HTTPStatus.OK,
                        collect_device_info(status.get("control_plane_url")),
                    )
                    return
                _serve_static(self, path)
                return

            if path == "/api/settings":
                _json_response(self, HTTPStatus.OK, read_settings())
                return

            if path == "/api/interfaces":
                _json_response(self, HTTPStatus.OK, {"interfaces": list_network_interfaces()})
                return

            if path == "/api/services":
                from .metrics import _systemd_active

                services = {
                    name: {"unit": unit, **_systemd_active(unit)}
                    for name, unit in SERVICE_UNITS.items()
                }
                _json_response(self, HTTPStatus.OK, {"services": services})
                return

            if path == "/api/logs":
                qs = parse_qs(parsed.query)
                service = (qs.get("service") or ["agent"])[0]
                lines = int((qs.get("lines") or ["200"])[0])
                _json_response(self, HTTPStatus.OK, tail_log(service, lines))
                return

            if path in ("/activate.html", "/flash.html"):
                self.send_response(HTTPStatus.MOVED_PERMANENTLY)
                flash_port = os.environ.get("GFC_CLIENT_FLASH_PORT", str(FLASH_PORT))
                host = self.headers.get("Host", "").split(":")[0] or "192.168.68.1"
                self.send_header("Location", f"http://{host}:{flash_port}/")
                self.end_headers()
                return

            _serve_static(self, path)
        except Exception as exc:  # noqa: BLE001
            _json_response(self, HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        try:
            if path == "/api/line-code":
                if self._mode == "admin":
                    _json_response(
                        self,
                        HTTPStatus.FORBIDDEN,
                        {"error": f"请使用刷码端口 {FLASH_PORT} 刷入线路码"},
                    )
                    return
                body = _read_json_body(self)
                code = str(body.get("code", "")).strip()
                reset_state = bool(body.get("reset_state", True))
                result = flash_line_code(code, reset_state=reset_state)
                _json_response(self, HTTPStatus.OK, result)
                return

            if self._mode == "flash":
                _json_response(self, HTTPStatus.FORBIDDEN, {"error": "刷码端口不支持此操作"})
                return

            if path == "/api/settings":
                body = _read_json_body(self)
                result = update_settings(body)
                _json_response(self, HTTPStatus.OK, result)
                return

            if path == "/api/service/restart":
                body = _read_json_body(self)
                name = str(body.get("service", "")).strip()
                result = restart_service(name)
                _json_response(self, HTTPStatus.OK, result)
                return

            self.send_error(HTTPStatus.NOT_FOUND)
        except ValueError as exc:
            _json_response(self, HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            _json_response(self, HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})


def _run_server(
    port: int,
    mode: str,
    web_root: Path,
    *,
    use_tls: bool = False,
) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", port), ClientWebHandler)
    server.web_root = web_root  # type: ignore[attr-defined]
    server.web_mode = mode  # type: ignore[attr-defined]
    scheme = "http"
    if use_tls:
        from .web_tls import ensure_self_signed_cert

        lan_ip = os.environ.get("GFC_LAN_ADDRESS", "192.168.68.1")
        cert, key = ensure_self_signed_cert(lan_ip)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(
        f"gfc-client-web mode={mode} {scheme}://0.0.0.0:{port} root={web_root}",
        flush=True,
    )
    server.serve_forever()


def main(argv: list[str] | None = None) -> int:
    import threading

    parser = argparse.ArgumentParser(description="GFC client box local web UI")
    parser.add_argument("--port", type=int, default=DEFAULT_WEB_PORT)
    parser.add_argument("--root", default=str(DEFAULT_WEB_ROOT))
    parser.add_argument(
        "--mode",
        choices=("admin", "flash", "both"),
        default=os.environ.get("GFC_WEB_MODE", "both"),
        help="admin=:80 flash=:81 both=同时监听两个端口",
    )
    args = parser.parse_args(argv)

    web_root = Path(args.root)
    web_root.mkdir(parents=True, exist_ok=True)

    if args.mode == "both":
        admin_port = int(os.environ.get("GFC_CLIENT_WEB_PORT", DEFAULT_WEB_PORT))
        flash_port = int(os.environ.get("GFC_CLIENT_FLASH_PORT", FLASH_PORT))
        https_port = int(os.environ.get("GFC_CLIENT_HTTPS_PORT", HTTPS_PORT))
        enable_https = os.environ.get("GFC_CLIENT_HTTPS", "1").strip() not in (
            "0",
            "false",
            "no",
        )
        threads: list[threading.Thread] = []
        listeners: list[tuple[int, str, bool]] = [
            (admin_port, "admin", False),
            (flash_port, "flash", False),
        ]
        if enable_https:
            listeners.append((https_port, "admin", True))
        for port, mode, tls in listeners:
            t = threading.Thread(
                target=_run_server,
                args=(port, mode, web_root),
                kwargs={"use_tls": tls},
                name=f"gfc-web-{port}{'-tls' if tls else ''}",
                daemon=True,
            )
            t.start()
            threads.append(t)
        print(
            f"gfc-client-web listeners: http admin=:{admin_port}"
            f" flash=:{flash_port}"
            + (f" https admin=:{https_port}" if enable_https else ""),
            flush=True,
        )
        for t in threads:
            t.join()
        return 0

    use_tls = os.environ.get("GFC_CLIENT_HTTPS", "").strip() in ("1", "true", "yes")
    _run_server(args.port, args.mode, web_root, use_tls=use_tls)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
