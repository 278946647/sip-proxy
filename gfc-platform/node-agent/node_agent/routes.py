from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-node"))
ROUTES_STATE = GFC_ETC / "static-routes.json"


def _run(cmd: list[str]) -> tuple[bool, str]:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0:
        return True, (r.stdout or "").strip()
    return False, (r.stderr or r.stdout or "failed").strip()


def default_route_iface() -> str | None:
    ok, out = _run(["ip", "-4", "route", "show", "default"])
    if not ok:
        return None
    for line in out.splitlines():
        parts = line.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    return None


def resolve_snat_iface() -> str | None:
    raw = os.environ.get("GFC_SNAT_IFACE", "auto").strip().lower()
    if raw in ("", "0", "false", "no", "off", "none"):
        return None
    if raw == "auto":
        return default_route_iface()
    return raw


def egress_snat_active(iface: str) -> bool:
    ok, out = _run(["nft", "list", "table", "ip", "gfc-nat"])
    return ok and f'oifname "{iface}"' in out and "masquerade" in out


def apply_egress_snat(iface: str | None) -> tuple[bool, str]:
    if not iface:
        return True, "snat disabled"
    subprocess.run(["nft", "delete", "table", "ip", "gfc-nat"], capture_output=True, text=True)
    script = f"""#!/usr/sbin/nft -f
table ip gfc-nat {{
  chain postrouting {{
    type nat hook postrouting priority srcnat; policy accept;
    oifname "{iface}" masquerade
  }}
}}
"""
    path = GFC_ETC / "gfc-snat.nft"
    path.write_text(script, encoding="utf-8")
    r = subprocess.run(["nft", "-f", str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"snat fail: {r.stderr or r.stdout}"
    return True, f"snat masquerade oif {iface}"


def tproxy_policy_active() -> bool:
    """TPROXY reply path needs fwmark 0x1 -> table 100 with local default via lo."""
    ok, rules = _run(["ip", "rule", "show"])
    if not ok or "fwmark 0x1" not in rules or "lookup 100" not in rules:
        return False
    ok, routes = _run(["ip", "route", "show", "table", "100"])
    return ok and "local" in routes


def ensure_tproxy_policy(tproxy_port: int) -> list[str]:
    """Policy routing for TPROXY reply path (mark 0x1 -> local table)."""
    _ = tproxy_port  # port is fixed in nftables; kept for call-site clarity
    msgs: list[str] = []
    if not tproxy_policy_active():
        ok, err = _run(["ip", "rule", "add", "fwmark", "0x1", "lookup", "100"])
        msgs.append("ip rule fwmark 1 -> table 100" if ok else f"ip rule warn: {err}")
    ok, routes = _run(["ip", "route", "show", "table", "100"])
    if "local" not in routes:
        ok, err = _run(
            ["ip", "route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", "100"]
        )
        msgs.append("ip route table 100 local" if ok else f"route local warn: {err}")
    elif not tproxy_policy_active():
        msgs.append("tproxy policy incomplete")
    else:
        msgs.append("tproxy policy ok")
    return msgs


def apply_static_routes(routes: list[dict[str, Any]]) -> tuple[bool, str]:
    ROUTES_STATE.parent.mkdir(parents=True, exist_ok=True)
    previous: list[dict[str, Any]] = []
    if ROUTES_STATE.is_file():
        try:
            raw = json.loads(ROUTES_STATE.read_text(encoding="utf-8"))
            if isinstance(raw, list):
                previous = raw
        except (OSError, json.JSONDecodeError):
            previous = []

    ROUTES_STATE.write_text(json.dumps(routes, ensure_ascii=False, indent=2), encoding="utf-8")

    messages: list[str] = []
    ok_all = True
    new_prefixes = {(r.get("prefix") or "").strip() for r in routes if (r.get("prefix") or "").strip()}

    for r in previous:
        prefix = (r.get("prefix") or "").strip()
        if not prefix or prefix in new_prefixes:
            continue
        ok, err = _run(["ip", "route", "del", prefix])
        if ok:
            messages.append(f"route {prefix} removed (stale)")
        else:
            messages.append(f"route {prefix} stale del warn: {err}")

    for r in routes:
        prefix = (r.get("prefix") or "").strip()
        if not prefix:
            continue
        next_hop = (r.get("nextHop") or r.get("next_hop") or "").strip() or None
        device = (r.get("device") or r.get("iface") or "").strip() or None
        if not device:
            device = os.environ.get("GFC_TPROXY_IFACE", "").strip() or None
        cmd = ["ip", "route", "replace", prefix]
        if next_hop:
            cmd += ["via", next_hop]
        if device:
            cmd += ["dev", device]
        elif next_hop:
            gr = subprocess.run(
                ["ip", "route", "get", next_hop],
                capture_output=True,
                text=True,
                check=False,
            )
            parts = (gr.stdout or "").split()
            if "dev" in parts:
                cmd += ["dev", parts[parts.index("dev") + 1]]
        ok, err = _run(cmd)
        if ok:
            messages.append(f"route {prefix} ok")
        else:
            ok_all = False
            messages.append(f"route {prefix} fail: {err}")

    if not routes:
        messages.append("no static routes configured")
    return ok_all, "; ".join(messages)
