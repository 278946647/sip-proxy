from __future__ import annotations

import os
import uuid
from pathlib import Path
from typing import Any

from .activation import ACTIVATION_FILE, STATE_FILE
from .apply import apply_payload, restart_dataplane_services
from .client import ControlPlaneClient
from .line_code import decode_line_code, is_line_activation_payload
from .routing_mode import read_routing_mode
from .runner import save_state
from .server_url import resolve_server_urls_from_env, urls_from_activation_payload


def _mac_address() -> str | None:
    node = uuid.getnode()
    if (node >> 40) % 2:
        return None
    return ":".join(f"{(node >> shift) & 0xFF:02x}" for shift in range(40, -1, -8))


def _device_id_from_mac(mac: str | None) -> str | None:
    if not mac:
        return None
    return mac.replace(":", "").upper()


def _read_activation(path: Path) -> tuple[str, dict[str, Any]]:
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        raise ValueError("activation file is empty")
    payload = decode_line_code(raw)
    if not is_line_activation_payload(payload):
        raise ValueError("not a line activation code")
    return raw, payload


def activate_and_apply(
    *,
    activation_file: Path | None = None,
    state_file: Path | None = None,
    config_dir: Path | None = None,
    device_name: str | None = None,
    proxy_mode: str | None = None,
) -> dict[str, Any]:
    """Activate with control plane, pull config, apply dataplane (CLI / flash)."""
    act_path = activation_file or ACTIVATION_FILE
    st_path = state_file or STATE_FILE
    cfg_dir = config_dir or Path(
        os.environ.get("CONFIG_DIR", "/opt/gfc-client/client-agent/state/dataplane")
    )
    proxy = (proxy_mode or os.environ.get("GFC_PROXY_MODE") or "gateway").strip()
    name = device_name or os.environ.get("DEVICE_NAME") or os.path.basename(
        os.environ.get("HOSTNAME", "gfc-client")
    )

    raw, payload = _read_activation(act_path)
    servers = urls_from_activation_payload(payload) or resolve_server_urls_from_env()
    if not servers:
        raise ValueError("no control plane URL in line code or gfc.env")

    import requests

    client = ControlPlaneClient(servers)
    lan_mac = _mac_address()
    device_id = _device_id_from_mac(lan_mac)

    try:
        state = client.activate(raw, name, lan_mac, device_id, proxy)
    except requests.HTTPError as exc:
        detail = ""
        if exc.response is not None:
            detail = (exc.response.text or "").strip()[:800]
        raise RuntimeError(
            f"activate failed HTTP {exc.response.status_code if exc.response else '?'}: {detail or exc}"
        ) from exc
    client = ControlPlaneClient(servers, state.client_token)
    save_state(str(st_path), state)

    cfg = client.pull_config()
    version = cfg["version"]
    body = cfg["payload"]
    body["proxyMode"] = proxy
    body["routingMode"] = read_routing_mode()
    body["controlPlaneServers"] = servers

    # Write configs first; ack while WAN still reachable, then restart sing-box/mosdns.
    ok, msg = apply_payload(body, cfg_dir, restart_services=False)
    ack_warning = ""
    try:
        if ok:
            client.ack_config(version, "applied", msg)
            state.applied_version = version
            save_state(str(st_path), state)
        else:
            client.ack_config(version, "failed", msg)
    except requests.RequestException as exc:
        ack_warning = str(exc)
        if ok:
            state.applied_version = version
            save_state(str(st_path), state)

    restart_msg = ""
    if ok:
        restart_msg = restart_dataplane_services()

    return {
        "ok": ok,
        "device_id": state.device_id,
        "tid": state.tid,
        "line_id": state.line_id,
        "server": client.server,
        "config_version": version,
        "apply_message": msg,
        "restart_message": restart_msg,
        "ack_warning": ack_warning or None,
    }
