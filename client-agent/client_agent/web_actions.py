from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

from .apply import apply_dns_config, reapply_local_config
from .easymosdns_update import update_easymosdns_rules
from .dns_lists import LIST_FILES, append_domains, export_list_text, import_list_text, read_list
from .line_code import code_kind, decode_line_code, is_platform_payload
from .network import apply_network, load_bridge_config, network_status, save_bridge_config
from .routing_mode import read_routing_mode, write_routing_mode

GFC_ENV = Path(os.environ.get("GFC_ENV_FILE", "/etc/gfc-client/gfc.env"))
ACTIVATION_FILE = Path(
    os.environ.get("ACTIVATION_FILE", "/etc/gfc-client/activation.b32")
)
PLATFORM_FILE = Path(
    os.environ.get("PLATFORM_FILE", "/etc/gfc-client/platform.b32")
)
STATE_FILE = Path(
    os.environ.get(
        "STATE_FILE",
        "/opt/gfc-client/client-agent/state/client_state.json",
    )
)
LOG_DIR = Path(os.environ.get("GFC_LOG_DIR", "/var/log/gfc-client"))

SERVICE_UNITS = {
    "agent": "gfc-client-agent.service",
    "sing-box": "gfc-client-sing-box.service",
    "mosdns": "gfc-mosdns.service",
    "web": "gfc-client-web.service",
    "flash": "gfc-client-flash.service",
    "dnsmasq": "dnsmasq.service",
}

LOG_FILES = {
    "agent": LOG_DIR / "gfc-client-agent.log",
    "sing-box": LOG_DIR / "sing-box.log",
    "mosdns": LOG_DIR / "mosdns.log",
    "web": LOG_DIR / "gfc-client-web.log",
    "flash": LOG_DIR / "gfc-client-flash.log",
}

ALLOWED_SETTINGS = {
    "device_name",
    "proxy_mode",
    "lan_iface",
    "wan_iface",
    "server_url",
    "server_url_fallback",
    "poll_seconds",
    "reverse_ssh_port",
}

ENV_KEY_MAP = {
    "device_name": "DEVICE_NAME",
    "proxy_mode": "GFC_PROXY_MODE",
    "lan_iface": "GFC_LAN_IFACE",
    "wan_iface": "GFC_WAN_IFACE",
    "server_url": "SERVER_URL",
    "server_url_fallback": "SERVER_URL_FALLBACK",
    "poll_seconds": "POLL_SECONDS",
    "reverse_ssh_port": "REVERSE_SSH_PORT",
}


def _read_env_lines() -> list[str]:
    if GFC_ENV.is_file():
        return GFC_ENV.read_text(encoding="utf-8").splitlines()
    return []


def _write_env_lines(lines: list[str]) -> None:
    GFC_ENV.parent.mkdir(parents=True, exist_ok=True)
    GFC_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(GFC_ENV, 0o600)


def _update_env_value(key: str, value: str) -> None:
    lines = _read_env_lines()
    prefix = f"{key}="
    replaced = False
    out: list[str] = []
    for line in lines:
        if line.startswith(prefix):
            out.append(f"{key}={value}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}={value}")
    _write_env_lines(out)


def _apply_server_urls(payload: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    server = (payload.get("server") or "").strip()
    if server:
        _update_env_value("SERVER_URL", server)
        urls.append(server)
    fallback = (payload.get("serverFallback") or "").strip()
    if fallback:
        _update_env_value("SERVER_URL_FALLBACK", fallback)
        urls.append(fallback)
    extra = payload.get("servers")
    if isinstance(extra, list) and extra and not server:
        first = str(extra[0]).strip()
        if first:
            _update_env_value("SERVER_URL", first)
            urls.append(first)
    return urls


def flash_line_code(
    code: str,
    *,
    reset_state: bool = True,
    restart_agent: bool = True,
) -> dict[str, Any]:
    normalized = code.strip()
    if not normalized:
        raise ValueError("线路码不能为空")

    try:
        payload = decode_line_code(normalized)
    except (ValueError, json.JSONDecodeError) as exc:
        raise ValueError(f"线路码格式无效: {exc}") from exc

    kind = code_kind(payload)
    GFC_ENV.parent.mkdir(parents=True, exist_ok=True)
    server_urls = _apply_server_urls(payload)

    if is_platform_payload(payload):
        PLATFORM_FILE.write_text(normalized, encoding="utf-8")
        os.chmod(PLATFORM_FILE, 0o600)
        restart_ok = _restart_service("agent")
        return {
            "ok": True,
            "kind": "platform",
            "server_urls": server_urls,
            "agent_restarted": restart_ok,
            "message": "平台地址已更新；请继续刷入客户端线路码完成激活",
        }

    ACTIVATION_FILE.write_text(normalized, encoding="utf-8")
    os.chmod(ACTIVATION_FILE, 0o600)

    if reset_state and STATE_FILE.is_file():
        STATE_FILE.unlink()

    restart_ok = False
    if restart_agent:
        restart_ok = _restart_service("agent")
    return {
        "ok": True,
        "kind": "line",
        "line_tid": payload.get("tid"),
        "line_id": payload.get("lineId"),
        "node_name": payload.get("nodeName"),
        "server_urls": server_urls,
        "agent_restarted": restart_ok,
        "message": "线路码已刷入，正在激活…",
    }


def update_settings(data: dict[str, Any]) -> dict[str, Any]:
    proxy_mode = str(data.get("proxy_mode", "")).strip().lower()
    if proxy_mode and proxy_mode not in ("gateway", "bypass", "transparent"):
        raise ValueError("proxy_mode 必须是 gateway / bypass / transparent")

    if proxy_mode == "transparent" and not str(data.get("lan_iface", "")).strip():
        raise ValueError("透明模式需要指定 LAN 网卡")

    poll = data.get("poll_seconds")
    if poll is not None:
        poll_int = int(poll)
        if poll_int < 5 or poll_int > 300:
            raise ValueError("poll_seconds 范围 5-300")

    updated: list[str] = []
    for field, env_key in ENV_KEY_MAP.items():
        if field not in data:
            continue
        val = str(data[field]).strip()
        _update_env_value(env_key, val)
        updated.append(field)

    restart_agent = "proxy_mode" in updated or "lan_iface" in updated or "wan_iface" in updated
    if restart_agent:
        _restart_service("agent")

    return {"ok": True, "updated": updated, "agent_restarted": restart_agent}


def _restart_service(name: str) -> bool:
    unit = SERVICE_UNITS.get(name)
    if not unit:
        raise ValueError(f"unknown service: {name}")
    if not Path("/bin/systemctl").exists():
        return False
    r = subprocess.run(
        ["systemctl", "restart", unit],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return r.returncode == 0


def restart_service(name: str) -> dict[str, Any]:
    ok = _restart_service(name)
    if not ok:
        raise RuntimeError(f"重启 {name} 失败")
    return {"ok": True, "service": name}


def get_dns_lists() -> dict[str, Any]:
    return {
        "lists": {
            name: {
                "path": str(path),
                "domains": read_list(name),
                "count": len(read_list(name)),
            }
            for name, path in LIST_FILES.items()
        }
    }


def update_dns_list(name: str, domains: list[str], *, action: str = "append") -> dict[str, Any]:
    if name not in LIST_FILES:
        raise ValueError(f"unknown list: {name}")
    cleaned = [d.strip() for d in domains if d.strip()]
    if not cleaned:
        raise ValueError("域名不能为空")
    if action == "replace":
        merged = import_list_text(name, "\n".join(cleaned), replace=True)  # type: ignore[arg-type]
    elif action == "append":
        merged = append_domains(name, cleaned)  # type: ignore[arg-type]
    else:
        raise ValueError("action 必须是 append 或 replace")
    ok, msg = apply_dns_config()
    return {
        "ok": ok,
        "list": name,
        "count": len(merged),
        "apply_message": msg,
    }


def import_dns_list(name: str, content: str, *, replace: bool) -> dict[str, Any]:
    if name not in LIST_FILES:
        raise ValueError(f"unknown list: {name}")
    merged = import_list_text(name, content, replace=replace)  # type: ignore[arg-type]
    ok, msg = apply_dns_config()
    return {"ok": ok, "list": name, "count": len(merged), "apply_message": msg}


def export_dns_list(name: str) -> dict[str, Any]:
    if name not in LIST_FILES:
        raise ValueError(f"unknown list: {name}")
    return {"list": name, "content": export_list_text(name)}  # type: ignore[arg-type]


def get_bridge_network() -> dict[str, Any]:
    return {"config": load_bridge_config(), "status": network_status()}


def apply_bridge_network(data: dict[str, Any]) -> dict[str, Any]:
    cfg = save_bridge_config(
        {
            "bridgeName": str(data.get("bridgeName", "")).strip() or None,
            "wan": str(data.get("wan", "")).strip() or None,
            "members": data.get("members") if isinstance(data.get("members"), list) else None,
            "lanAddress": str(data.get("lanAddress", "")).strip() or None,
            "lanPrefix": int(data["lanPrefix"]) if data.get("lanPrefix") not in (None, "") else None,
        }
    )
    ok, msg = apply_network(bridge_config=cfg)
    if not ok:
        raise RuntimeError(msg)
    return {"ok": True, "config": cfg, "message": msg}


def easymosdns_update(source: str) -> dict[str, Any]:
    src = source.strip().lower()
    if src not in ("github", "cdn"):
        raise ValueError("source 必须是 github（update）或 cdn（update-cdn）")
    return update_easymosdns_rules(src)  # type: ignore[arg-type]


def get_singbox_routing() -> dict[str, Any]:
    return {"mode": read_routing_mode()}


def set_singbox_routing(mode: str) -> dict[str, Any]:
    mode = mode.strip().lower()
    if mode not in ("split", "global"):
        raise ValueError("mode 必须是 split（分流）或 global（全走国际）")
    write_routing_mode(mode)  # type: ignore[arg-type]
    ok, msg = reapply_local_config()
    restart_ok = _restart_service("sing-box")
    return {
        "ok": ok,
        "mode": mode,
        "apply_message": msg,
        "sing_box_restarted": restart_ok,
    }


def tail_log(service: str, lines: int = 200) -> dict[str, Any]:
    if service not in LOG_FILES:
        raise ValueError(f"unknown log service: {service}")
    path = LOG_FILES[service]
    lines = max(20, min(2000, int(lines)))
    if not path.is_file():
        return {"service": service, "path": str(path), "lines": [], "message": "日志文件不存在"}
    try:
        r = subprocess.run(
            ["tail", "-n", str(lines), str(path)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        content = r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        content = path.read_text(encoding="utf-8", errors="replace")
        content = "\n".join(content.splitlines()[-lines:])

    content = re.sub(r"\x1b\[[0-9;]*m", "", content)
    return {
        "service": service,
        "path": str(path),
        "lines": content.splitlines(),
    }
