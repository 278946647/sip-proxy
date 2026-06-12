from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

from .dns_lists import LIST_FILES, ensure_default_lists
from .easymosdns_fetch import fetch

EASYMODNS_CONFIG_URL = "https://raw.githubusercontent.com/pmkol/easymosdns/main/config.yaml"

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
EASYMODNS_DIR = GFC_ETC / "mosdns" / "easymosdns"
EASYMODNS_RULES = EASYMODNS_DIR / "rules"
MOSDNS_CONFIG = GFC_ETC / "mosdns" / "config.yaml"

GFC_DATA_PROVIDERS = """
  - tag: gfc_block
    file: {block}
    auto_reload: true
  - tag: gfc_china
    file: {china}
    auto_reload: true
  - tag: gfc_global
    file: {global_list}
    auto_reload: true
"""

GFC_PLUGINS = """
  - tag: query_is_gfc_block
    type: query_matcher
    args:
      domain:
        - "provider:gfc_block"
  - tag: query_is_gfc_china
    type: query_matcher
    args:
      domain:
        - "provider:gfc_china"
  - tag: query_is_gfc_global
    type: query_matcher
    args:
      domain:
        - "provider:gfc_global"
"""

GFC_SEQUENCE_PREFIX = """
        - if: query_is_gfc_block
          exec:
            - black_hole
            - ttl_1h
            - _return
        - if: query_is_gfc_china
          exec:
            - forward_local
            - ttl_5m
            - _return
        - if: query_is_gfc_global
          exec:
            - _prefer_ipv4
            - forward_remote
            - ttl_5m
            - _return
"""


def ensure_easymosdns_tree(*, try_download: bool = True) -> Path:
    ensure_default_lists()
    EASYMODNS_DIR.mkdir(parents=True, exist_ok=True)
    EASYMODNS_RULES.mkdir(parents=True, exist_ok=True)

    template_path = EASYMODNS_DIR / "config.yaml"
    if not template_path.is_file() and try_download:
        raw = fetch(EASYMODNS_CONFIG_URL).decode("utf-8", errors="replace")
        template_path.write_text(raw, encoding="utf-8")

    if try_download and shutil.which("curl"):
        from .easymosdns_update import update_easymosdns_rules

        try:
            update_easymosdns_rules("cdn")
        except RuntimeError:
            try:
                update_easymosdns_rules("github")
            except RuntimeError:
                pass

    for name in ("ecs_cn_domain.txt", "ecs_noncn_domain.txt", "hosts.txt"):
        dst = EASYMODNS_DIR / name
        if not dst.is_file():
            try:
                dst.write_bytes(fetch(f"https://raw.githubusercontent.com/pmkol/easymosdns/main/{name}"))
            except RuntimeError:
                dst.write_text("# placeholder\n", encoding="utf-8")

    return EASYMODNS_DIR


def _patch_paths(raw: str, base: Path) -> str:
    rules = base / "rules"
    text = raw.replace("./rules/", f"{rules}/")
    text = text.replace("./ecs_cn_domain.txt", str(base / "ecs_cn_domain.txt"))
    text = text.replace("./ecs_noncn_domain.txt", str(base / "ecs_noncn_domain.txt"))
    text = text.replace("./hosts.txt", str(base / "hosts.txt"))
    text = re.sub(r'addr:\s*"0\.0\.0\.0:53"', 'addr: "127.0.0.1:5335"', text)
    text = re.sub(r"addr:\s*'0\.0\.0\.0:53'", "addr: '127.0.0.1:5335'", text)
    return text


def _inject_gfc_overlay(raw: str) -> str:
    if "gfc_block" in raw:
        return raw

    block = LIST_FILES["block"]
    china = LIST_FILES["china"]
    global_f = LIST_FILES["global"]

    providers = GFC_DATA_PROVIDERS.format(block=block, china=china, global_list=global_f)
    if "data_providers:" in raw:
        raw = raw.replace("data_providers:", "data_providers:" + providers, 1)
    elif "plugins:" in raw:
        raw = raw.replace("plugins:", f"data_providers:{providers}\n\nplugins:", 1)

    if "plugins:" in raw and "query_is_gfc_block" not in raw:
        raw = raw.replace("plugins:", "plugins:" + GFC_PLUGINS, 1)

    marker = "  - tag: main_sequence"
    if marker in raw and "query_is_gfc_block" not in raw.split(marker, 1)[-1][:800]:
        raw = raw.replace(
            "      exec:",
            f"      exec:{GFC_SEQUENCE_PREFIX}",
            1,
        )

    return raw


def render_mosdns_config_file(*, try_download: bool = True) -> str:
    base = ensure_easymosdns_tree(try_download=try_download)
    src = base / "config.yaml"
    if not src.is_file():
        raise RuntimeError("easymosdns config.yaml missing — run fetch-easymosdns-lists.sh")

    raw = _patch_paths(src.read_text(encoding="utf-8"), base)
    raw = _inject_gfc_overlay(raw)

    MOSDNS_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    MOSDNS_CONFIG.write_text(raw, encoding="utf-8")
    return raw


def mosdns_config_ok(path: Path | None = None) -> tuple[bool, str]:
    cfg = path or MOSDNS_CONFIG
    if not cfg.is_file():
        return False, "missing config"
    mosdns_bin = "/usr/local/bin/mosdns"
    if not Path(mosdns_bin).exists():
        from shutil import which

        if not which("mosdns"):
            return False, "mosdns binary not found"
        mosdns_bin = "mosdns"

    workdir = cfg.parent
    r = subprocess.run(
        ["timeout", "3", mosdns_bin, "start", "-c", str(cfg)],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode == 124:
        return True, ""
    err = (r.stderr or r.stdout or "config check failed").strip()
    return False, err
