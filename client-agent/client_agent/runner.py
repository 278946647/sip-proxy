from __future__ import annotations

import argparse
import json
import os
import uuid
from pathlib import Path
from typing import Any

from .activation import is_line_activated
from .apply import apply_payload
from .bootstrap import ensure_bootstrap_dataplane
from .routing_mode import read_routing_mode
from .client import ControlPlaneClient, ClientState
from .device_info import collect_device_info
from .line_code import decode_line_code, is_line_activation_payload
from .metrics import collect_metrics, write_status_snapshot
from .network import apply_network
from .server_url import parse_server_url_list, resolve_server_urls_from_env, urls_from_activation_payload
from .singbox import singbox_config_ok
from .sysctl_util import ensure_network_tuning
from .version import AGENT_VERSION


def _mac_address() -> str | None:
    node = uuid.getnode()
    if (node >> 40) % 2:
        return None
    return ":".join(f"{(node >> shift) & 0xFF:02x}" for shift in range(40, -1, -8))


def _device_id_from_mac(mac: str | None) -> str | None:
    if not mac:
        return None
    return mac.replace(":", "").upper()


def load_state(path: str) -> ClientState | None:
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return ClientState(
        device_id=data["device_id"],
        device_key=data["device_key"],
        client_token=data["client_token"],
        line_id=data["line_id"],
        tid=data["tid"],
        applied_version=data.get("applied_version"),
    )


def save_state(path: str, state: ClientState) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "device_id": state.device_id,
                "device_key": state.device_key,
                "client_token": state.client_token,
                "line_id": state.line_id,
                "tid": state.tid,
                "applied_version": state.applied_version,
            },
            f,
            ensure_ascii=False,
            indent=2,
        )


def _read_activation_raw(path: str) -> tuple[str | None, dict[str, Any] | None]:
    if not os.path.isfile(path):
        return None, None
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
        if not raw:
            return None, None
        payload = decode_line_code(raw)
        if not is_line_activation_payload(payload):
            return None, payload
        return raw, payload
    except (OSError, ValueError):
        return None, None


def resolve_server_urls(args: argparse.Namespace, activation: dict[str, Any] | None) -> list[str]:
    urls = parse_server_url_list(
        args.server,
        args.server_fallback,
        os.environ.get("SERVER_URL"),
        os.environ.get("SERVER_URL_FALLBACK"),
        os.environ.get("SERVER_URLS"),
    )
    if urls:
        return urls
    from_line = urls_from_activation_payload(activation)
    if from_line:
        return from_line
    env_urls = resolve_server_urls_from_env()
    if env_urls:
        return env_urls
    return []


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=f"GFC client box agent v{AGENT_VERSION}")
    p.add_argument("--server", help="Control plane API URL (optional if in line code)")
    p.add_argument("--server-fallback", help="Fallback control plane URL")
    p.add_argument("--line-code", help="Base32 line code string")
    p.add_argument(
        "--activation-file",
        default="/etc/gfc-client/activation.b32",
        help="Path to Base32 line activation file",
    )
    p.add_argument("--device-name", default=os.environ.get("DEVICE_NAME") or None)
    p.add_argument(
        "--proxy-mode",
        default=os.environ.get("GFC_PROXY_MODE", "gateway"),
        choices=["gateway", "bypass", "transparent"],
    )
    p.add_argument("--state-file", default="./state/client_state.json")
    p.add_argument("--config-dir", default="./state/dataplane")
    p.add_argument("--poll-seconds", type=int, default=10)
    p.add_argument("--status-file", default="/var/lib/gfc-client/status.json")
    p.add_argument(
        "--skip-network-setup",
        action="store_true",
        help="Skip OpenWrt-style WAN/LAN apply on startup",
    )
    return p


def _write_idle_status(
    status_file: Path,
    *,
    message: str,
    server_url: str | None = None,
    lan_iface: str | None = None,
) -> None:
    reachable = False
    if server_url:
        try:
            reachable = ControlPlaneClient([server_url]).check_reachable()
        except ValueError:
            reachable = False
    metrics = collect_metrics(server_url or "", reachable, lan_iface)
    metrics["agent_state"] = "waiting_line_code"
    metrics["agent_message"] = message
    device_info = collect_device_info(server_url)
    write_status_snapshot(
        metrics,
        status_file,
        control_plane_url=server_url,
        device=device_info,
    )


def run_loop(args: argparse.Namespace) -> None:
    import time

    if not args.skip_network_setup:
        ok, net_msg = apply_network()
        print(f"network: {net_msg}" if ok else f"network skip/fail: {net_msg}", flush=True)

    print(f"sysctl: {ensure_network_tuning()}", flush=True)

    if not is_line_activated():
        ok, boot_msg = ensure_bootstrap_dataplane(try_download=False)
        print(f"bootstrap: {boot_msg}" if ok else f"bootstrap warn: {boot_msg}", flush=True)

    device_name = args.device_name or os.environ.get("HOSTNAME", "gfc-client")
    lan_mac = _mac_address()
    device_id = _device_id_from_mac(lan_mac)
    reverse_ssh_port = int(os.environ.get("REVERSE_SSH_PORT", "0") or 0) or None
    config_dir = Path(args.config_dir)
    status_file = Path(args.status_file)
    lan_iface = os.environ.get("GFC_LAN_IFACE", "").strip() or None

    state = load_state(args.state_file)
    client: ControlPlaneClient | None = None

    while True:
        try:
            raw_code, activation = _read_activation_raw(args.activation_file)
            if args.line_code:
                raw_code = args.line_code.strip()
                activation = decode_line_code(raw_code)

            if not state:
                servers = resolve_server_urls(args, activation)
                if not raw_code or not activation:
                    _write_idle_status(
                        status_file,
                        message="请通过 http://192.168.68.1:81 刷入线路码",
                        server_url=servers[0] if servers else None,
                        lan_iface=lan_iface,
                    )
                    print("waiting for line code (flash at :81)", flush=True)
                    time.sleep(args.poll_seconds)
                    continue
                if not servers:
                    _write_idle_status(
                        status_file,
                        message="线路码缺少控制平台地址，请刷入完整线路码或平台码",
                        lan_iface=lan_iface,
                    )
                    print("waiting for control plane URL in line code or env", flush=True)
                    time.sleep(args.poll_seconds)
                    continue

                client = ControlPlaneClient(servers)
                state = client.activate(
                    raw_code,
                    device_name,
                    lan_mac,
                    device_id,
                    args.proxy_mode,
                )
                client = ControlPlaneClient(servers, state.client_token)
                save_state(args.state_file, state)
                print(
                    f"activated device_id={state.device_id} line={state.tid} via {client.server}",
                    flush=True,
                )
            elif client is None:
                servers = resolve_server_urls(args, activation)
                if not servers:
                    raise ValueError("control plane SERVER_URL not configured")
                client = ControlPlaneClient(servers, state.client_token)

            assert client is not None
            reachable = client.check_reachable()
            metrics = collect_metrics(client.server, reachable, lan_iface)
            metrics["agent_state"] = "active"
            device_info = collect_device_info(client.server)
            write_status_snapshot(
                metrics,
                status_file,
                control_plane_url=client.server,
                device=device_info,
            )
            client.heartbeat(metrics, device_name, reverse_ssh_port, args.proxy_mode)

            cfg = client.pull_config()
            version = cfg["version"]
            payload = cfg["payload"]
            payload["proxyMode"] = args.proxy_mode
            payload["routingMode"] = read_routing_mode()

            need_apply = state.applied_version != version
            if not need_apply:
                ok_sb, _ = singbox_config_ok()
                if not ok_sb:
                    need_apply = True
            if not need_apply:
                bundle = config_dir / "config_bundle.json"
                if bundle.exists():
                    try:
                        old = json.loads(bundle.read_text(encoding="utf-8"))
                        if old.get("proxyMode") != payload.get("proxyMode"):
                            need_apply = True
                    except (OSError, json.JSONDecodeError):
                        need_apply = True

            if need_apply:
                ok, msg = apply_payload(payload, config_dir)
                if ok:
                    client.ack_config(version, "applied", msg)
                    state.applied_version = version
                    save_state(args.state_file, state)
                    print(f"applied version={version} ({msg})", flush=True)
                else:
                    client.ack_config(version, "failed", msg)
                    print(f"apply failed version={version}: {msg}", flush=True)
            else:
                print(f"config unchanged version={version}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"error: {e}", flush=True)
        time.sleep(args.poll_seconds)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.device_name:
        import socket

        args.device_name = socket.gethostname()
    run_loop(args)
    return 0
