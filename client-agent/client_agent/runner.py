from __future__ import annotations

import argparse
import json
import os
import uuid
from pathlib import Path
from typing import Any

from .apply import apply_payload
from .client import ControlPlaneClient, ClientState
from .line_code import read_activation_file
from .server_url import parse_server_url_list, resolve_server_urls_from_env, urls_from_activation_payload
from .metrics import collect_metrics, write_status_snapshot
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
    raise ValueError("control plane SERVER_URL not set (env, --server, or line code)")


def resolve_line_code(args: argparse.Namespace) -> str:
    if args.line_code:
        return args.line_code.strip()
    path = args.activation_file or os.environ.get(
        "ACTIVATION_FILE", "/etc/gfc-client/activation.b32"
    )
    if os.path.isfile(path):
        activation = read_activation_file(path)
        # File contains full payload; re-encode not needed if we store raw b32
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    raise ValueError(f"line code not found: set --line-code or {path}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=f"GFC client box agent v{AGENT_VERSION}")
    p.add_argument(
        "--server",
        help="Control plane API URL (IP or domain; optional if embedded in line code)",
    )
    p.add_argument(
        "--server-fallback",
        help="Fallback control plane URL when primary is unreachable",
    )
    p.add_argument("--line-code", help="Base32 line code string")
    p.add_argument(
        "--activation-file",
        default="/etc/gfc-client/activation.b32",
        help="Path to Base32 activation file",
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
    return p


def run_loop(args: argparse.Namespace) -> None:
    activation: dict[str, Any] | None = None
    act_path = args.activation_file
    if os.path.isfile(act_path):
        try:
            with open(act_path, "r", encoding="utf-8") as f:
                raw_code = f.read().strip()
            activation = read_activation_file(raw_code) if raw_code else None
        except (OSError, ValueError):
            activation = None

    servers = resolve_server_urls(args, activation)
    device_name = args.device_name or os.environ.get("HOSTNAME", "gfc-client")
    lan_mac = _mac_address()
    device_id = _device_id_from_mac(lan_mac)
    reverse_ssh_port = int(os.environ.get("REVERSE_SSH_PORT", "0") or 0) or None

    state = load_state(args.state_file)
    if not state:
        line_code = resolve_line_code(args)
        client = ControlPlaneClient(servers)
        state = client.activate(
            line_code,
            device_name,
            lan_mac,
            device_id,
            args.proxy_mode,
        )
        client = ControlPlaneClient(servers, state.client_token)
        save_state(args.state_file, state)
        print(
            f"activated device_id={state.device_id} line={state.tid} name={device_name} via {client.server}",
            flush=True,
        )
    else:
        client = ControlPlaneClient(servers, state.client_token)

    config_dir = Path(args.config_dir)
    status_file = Path(args.status_file)
    lan_iface = os.environ.get("GFC_LAN_IFACE", "").strip() or None

    print(f"sysctl: {ensure_network_tuning()}", flush=True)

    import time

    while True:
        try:
            reachable = client.check_reachable()
            metrics = collect_metrics(client.server, reachable, lan_iface)
            write_status_snapshot(metrics, status_file)
            client.heartbeat(
                metrics,
                device_name,
                reverse_ssh_port,
                args.proxy_mode,
            )

            cfg = client.pull_config()
            version = cfg["version"]
            payload = cfg["payload"]
            payload["proxyMode"] = args.proxy_mode

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
