#!/usr/bin/env python3
"""One-shot activation: decode line code file and register device with control plane."""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import uuid

from client_agent.client import ControlPlaneClient
from client_agent.line_code import decode_line_code, read_activation_file
from client_agent.runner import save_state, ClientState


def _mac() -> str | None:
    node = uuid.getnode()
    if (node >> 40) % 2:
        return None
    return ":".join(f"{(node >> s) & 0xFF:02x}" for s in range(40, -1, -8))


def main() -> int:
    p = argparse.ArgumentParser(description="Activate GFC client with Base32 line code")
    p.add_argument("--file", default="/etc/gfc-client/activation.b32")
    p.add_argument("--line-code", help="Base32 string instead of file")
    p.add_argument("--server", help="Override control plane URL")
    p.add_argument("--device-name", default=socket.gethostname())
    p.add_argument("--proxy-mode", default="gateway", choices=["gateway", "bypass", "transparent"])
    p.add_argument("--state-file", default="/opt/gfc-client/client-agent/state/client_state.json")
    args = p.parse_args()

    code = args.line_code.strip() if args.line_code else open(args.file, encoding="utf-8").read().strip()
    payload = decode_line_code(code) if args.line_code else read_activation_file(args.file)
    server = (args.server or payload.get("server") or os.environ.get("SERVER_URL", "")).rstrip("/")
    if not server:
        print("ERROR: control plane URL missing", file=sys.stderr)
        return 1

    mac = _mac()
    device_id = mac.replace(":", "").upper() if mac else None
    client = ControlPlaneClient(server)
    state = client.activate(code, args.device_name, mac, device_id, args.proxy_mode)
    save_state(args.state_file, state)
    print(json.dumps({"ok": True, "device_id": state.device_id, "tid": state.tid, "server": server}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
