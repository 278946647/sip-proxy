from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

from .dns_lists import LIST_FILES, ensure_default_lists

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
MOSDNS_CONFIG = GFC_ETC / "mosdns.yaml"


def mosdns_config_ok(path: Path | None = None) -> tuple[bool, str]:
    cfg = path or MOSDNS_CONFIG
    if not cfg.is_file():
        return False, "missing config"
    if not Path("/usr/local/bin/mosdns").exists() and not _which("mosdns"):
        return False, "mosdns binary not found"
    mosdns_bin = "/usr/local/bin/mosdns" if Path("/usr/local/bin/mosdns").exists() else "mosdns"
    r = subprocess.run(
        ["timeout", "2", mosdns_bin, "start", "-c", str(cfg)],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode == 124:
        return True, ""
    err = (r.stderr or r.stdout or "config check failed").strip()
    return False, err


def _which(name: str) -> bool:
    from shutil import which

    return which(name) is not None


def _upstream_yaml(addrs: list[str]) -> str:
    lines = []
    for addr in addrs:
        lines.append(f'        - addr: "{addr}"')
    return "\n".join(lines)


def render_mosdns_config(payload: dict[str, Any] | None = None) -> str:
    payload = payload or {}
    dns = payload.get("dns") or {}
    domestic_addrs = dns.get("domesticServers") or [dns.get("domesticServer") or "223.5.5.5"]
    intl_addrs = dns.get("intlServers") or [dns.get("intlServer") or "1.1.1.1"]
    if isinstance(domestic_addrs, str):
        domestic_addrs = [domestic_addrs]
    if isinstance(intl_addrs, str):
        intl_addrs = [intl_addrs]
    domestic_addrs = [str(a).strip() for a in domestic_addrs if str(a).strip()] or ["223.5.5.5"]
    intl_addrs = [str(a).strip() for a in intl_addrs if str(a).strip()] or ["1.1.1.1", "8.8.8.8"]

    ensure_default_lists()
    block_path = LIST_FILES["block"]
    china_path = LIST_FILES["china"]
    global_path = LIST_FILES["global"]

    return f"""# GFC client mosdns — easymosdns-style split (block / china / global)
log:
  level: info

plugins:
  - tag: block_domains
    type: domain_set
    args:
      files:
        - {block_path}

  - tag: china_domains
    type: domain_set
    args:
      files:
        - {china_path}

  - tag: global_domains
    type: domain_set
    args:
      files:
        - {global_path}

  - tag: forward_china
    type: forward
    args:
      upstreams:
{_upstream_yaml(domestic_addrs)}

  - tag: forward_global
    type: forward
    args:
      upstreams:
{_upstream_yaml(intl_addrs)}

  - tag: lazy_cache
    type: cache
    args:
      size: 8192
      lazy_cache_ttl: 86400

  - tag: main_sequence
    type: sequence
    args:
      - matches:
          - qname $block_domains
        exec: reject 3
      - exec: $lazy_cache
      - matches:
          - qname $china_domains
        exec: $forward_china
      - matches:
          - qname $global_domains
        exec: $forward_global
      - matches:
          - qname .cn
        exec: $forward_china
      - exec: $forward_global

  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:5335

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: 127.0.0.1:5335
"""
