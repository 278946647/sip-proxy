from __future__ import annotations

import argparse
import json
import os
import socket
import time
from pathlib import Path
from typing import Any

from .apply import apply_payload, nftables_tproxy_active
from .client import ControlPlaneClient, NodeState
from .server_url import parse_server_url_list, resolve_server_urls_from_env
from .metrics import collect_metrics
from .env_sync import read_bootstrap_token, sync_bootstrap_token
from .routes import ROUTES_STATE, egress_snat_active, resolve_snat_iface, tproxy_policy_active
from .singbox import singbox_config_ok
from .socks_health import dns_health_changed, evaluate_socks_dns_health
from .sysctl_util import ensure_network_tuning
from .version import AGENT_VERSION


def load_state(path: str) -> NodeState | None:
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    return NodeState(
        node_id=data["node_id"],
        node_key=data["node_key"],
        node_token=data["node_token"],
        applied_version=data.get("applied_version"),
    )


def save_state(path: str, state: NodeState) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "node_id": state.node_id,
                "node_key": state.node_key,
                "node_token": state.node_token,
                "applied_version": state.applied_version,
            },
            f,
            ensure_ascii=False,
            indent=2,
        )


def _routes_need_apply(payload: dict[str, Any]) -> bool:
    want = payload.get("staticRoutes") or []
    if not want:
        return False
    if not ROUTES_STATE.is_file():
        return True
    try:
        saved = json.loads(ROUTES_STATE.read_text(encoding="utf-8"))
        return saved != want
    except (OSError, json.JSONDecodeError):
        return True


def detect_public_ip() -> str | None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def resolve_server_urls(args: argparse.Namespace) -> list[str]:
    urls = parse_server_url_list(
        args.server,
        args.server_fallback,
        os.environ.get("SERVER_URL_FALLBACK"),
        os.environ.get("SERVER_URLS"),
    )
    if urls:
        return urls
    env_urls = resolve_server_urls_from_env()
    if env_urls:
        return env_urls
    raise ValueError("control plane SERVER_URL not set (--server or SERVER_URL env)")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=f"GFC forward node agent v{AGENT_VERSION}")
    p.add_argument(
        "--server",
        help="Control plane API URL (IP or domain); comma-separated for multiple",
    )
    p.add_argument(
        "--server-fallback",
        help="Fallback control plane URL when primary is unreachable",
    )
    p.add_argument("--bootstrap-token", required=True, help="Bootstrap token")
    p.add_argument("--node-name", required=True, help="Node display name (synced to control plane)")
    p.add_argument("--region", required=True, help="Node region")
    p.add_argument("--state-file", default="./state/node_state.json")
    p.add_argument("--config-dir", default="./state/dataplane")
    p.add_argument("--poll-seconds", type=int, default=10)
    return p


def run_loop(args: argparse.Namespace) -> None:
    servers = resolve_server_urls(args)
    state = load_state(args.state_file)
    client: ControlPlaneClient

    if not state:
        client = ControlPlaneClient(servers)
        state = client.activate(
            args.bootstrap_token,
            args.node_name,
            args.region,
            detect_public_ip(),
        )
        client = ControlPlaneClient(servers, state.node_token)
        save_state(args.state_file, state)
        print(
            f"activated node_id={state.node_id} name={args.node_name} via {client.server}",
            flush=True,
        )
    else:
        client = ControlPlaneClient(servers, state.node_token)

    config_dir = Path(args.config_dir)
    print(f"sysctl: {ensure_network_tuning()}", flush=True)

    while True:
        try:
            reachable = client.check_reachable()
            metrics = collect_metrics(
                client.server, reachable, Path(args.config_dir), args.poll_seconds
            )
            client.heartbeat(metrics, args.node_name, detect_public_ip())

            cfg = client.pull_config()
            version = cfg["version"]
            payload = cfg["payload"]

            need_apply = state.applied_version != version
            if not need_apply and _routes_need_apply(payload):
                need_apply = True
            if not need_apply:
                ok_sb, _ = singbox_config_ok()
                if not ok_sb:
                    need_apply = True
            if not need_apply:
                bundle_path = config_dir / "config_bundle.json"
                if bundle_path.exists():
                    try:
                        old = json.loads(bundle_path.read_text(encoding="utf-8"))
                        if old.get("staticRoutes") != payload.get("staticRoutes"):
                            need_apply = True
                        if old.get("connectMode") != payload.get("connectMode"):
                            need_apply = True
                        if old.get("vpn") != payload.get("vpn"):
                            need_apply = True
                        if old.get("tproxyIface") != payload.get("tproxyIface"):
                            need_apply = True
                        if old.get("clientIngress") != payload.get("clientIngress"):
                            need_apply = True
                    except (OSError, json.JSONDecodeError):
                        need_apply = True
            tproxy_iface = (payload.get("tproxyIface") or "").strip() or os.environ.get(
                "GFC_TPROXY_IFACE", ""
            ).strip()
            if not need_apply and tproxy_iface and not nftables_tproxy_active():
                need_apply = True
            if not need_apply and tproxy_iface and not tproxy_policy_active():
                need_apply = True
            snat_iface = resolve_snat_iface()
            if not need_apply and snat_iface and not egress_snat_active(snat_iface):
                need_apply = True
            want_bootstrap = (payload.get("bootstrapToken") or "").strip()
            if want_bootstrap and read_bootstrap_token() != want_bootstrap:
                need_apply = True
            socks_dns_ok = evaluate_socks_dns_health(payload, config_dir)
            if not need_apply and dns_health_changed(config_dir, socks_dns_ok):
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
                drift = sync_bootstrap_token(payload.get("bootstrapToken"))
                if drift:
                    print(drift, flush=True)
                print(f"config unchanged version={version}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"error: {e}", flush=True)
        time.sleep(args.poll_seconds)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    run_loop(args)
    return 0
