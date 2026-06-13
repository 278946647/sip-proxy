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
    auto_reload: false
  - tag: gfc_china
    file: {china}
    auto_reload: false
  - tag: gfc_global
    file: {global_list}
    auto_reload: false
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

# International DNS: DoH over HTTPS (routed via VLESS), not UDP :53 through proxy.
INTL_DOH_UPSTREAMS_YAML = """
  - tag: forward_remote
    type: fast_forward
    args:
      upstream:
        - addr: "https://1.1.1.1/dns-query"
          dial_addr: "1.1.1.1:443"
          enable_http3: false
        - addr: "https://8.8.8.8/dns-query"
          dial_addr: "8.8.8.8:443"
          enable_http3: false
"""

INTL_DOH_EASYMODNS_YAML = """
  - tag: forward_easymosdns
    type: fast_forward
    args:
      upstream:
        - addr: "https://1.1.1.1/dns-query"
          dial_addr: "1.1.1.1:443"
          enable_http3: false
        - addr: "https://8.8.8.8/dns-query"
          dial_addr: "8.8.8.8:443"
          enable_http3: false
"""

_LEGACY_FORWARD_REMOTE = """  - tag: forward_remote
    type: fast_forward
    args:
      upstream:
        - addr: "tcp://208.67.220.220:5353"
          enable_pipeline: true
          #socks5: "127.0.0.1:1080"
        - addr: "udpme://8.8.8.8\""""

_LEGACY_FORWARD_EASYMODNS = """  - tag: forward_easymosdns
    type: fast_forward
    args:
      upstream:
        - addr: "https://mosdns.apad.pro/api-query"
          bootstrap: "223.6.6.6"
          #dial_addr: "ip:port\""""

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


LEGACY_MOSDNS = GFC_ETC / "mosdns.yaml"


def remove_legacy_mosdns_files() -> None:
    if LEGACY_MOSDNS.is_file():
        LEGACY_MOSDNS.unlink(missing_ok=True)


def mosdns_binary_ok() -> tuple[bool, str]:
    mosdns_bin = "/usr/local/bin/mosdns"
    if not Path(mosdns_bin).exists():
        from shutil import which

        mosdns_bin = which("mosdns") or ""
    if not mosdns_bin:
        return False, "mosdns binary not found"
    r = subprocess.run(
        [mosdns_bin, "version"],
        capture_output=True,
        text=True,
        check=False,
    )
    out = f"{r.stdout or ''}{r.stderr or ''}".strip()
    if re.search(r"\bv5\.\d", out):
        return False, f"mosdns v5 detected ({out}), need mosdns-x"
    if "build time" not in out and "main" not in out.lower():
        return False, f"unknown mosdns build: {out or 'no output'}"
    return True, out


def _validate_easymosdns_schema(raw: str) -> None:
    if "domain_set" in raw or "block_domains" in raw:
        raise RuntimeError("legacy mosdns v5 yaml (domain_set) — need easymosdns template")
    if "main_sequence" not in raw and "data_providers" not in raw:
        raise RuntimeError("not easymosdns schema (missing main_sequence/data_providers)")


def ensure_easymosdns_tree(*, try_download: bool = True) -> Path:
    remove_legacy_mosdns_files()
    ensure_default_lists()
    EASYMODNS_DIR.mkdir(parents=True, exist_ok=True)
    EASYMODNS_RULES.mkdir(parents=True, exist_ok=True)

    template_path = EASYMODNS_DIR / "config.yaml"
    if template_path.is_file():
        try:
            _validate_easymosdns_schema(template_path.read_text(encoding="utf-8"))
        except RuntimeError:
            template_path.unlink(missing_ok=True)

    if not template_path.is_file():
        try:
            raw = fetch(EASYMODNS_CONFIG_URL).decode("utf-8", errors="replace")
            template_path.write_text(raw, encoding="utf-8")
        except RuntimeError:
            if try_download:
                raise

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


def _patch_intl_doh_upstream(raw: str) -> str:
    """International DNS via DoH; HTTPS egress is proxied by sing-box (not UDP DNS-in-VLESS)."""
    if "https://1.1.1.1/dns-query" in raw and "forward_remote" in raw:
        return raw
    if _LEGACY_FORWARD_REMOTE in raw:
        raw = raw.replace(_LEGACY_FORWARD_REMOTE, INTL_DOH_UPSTREAMS_YAML.strip())
    elif "  - tag: forward_remote" in raw:
        raw = re.sub(
            r"  - tag: forward_remote\n    type: fast_forward\n    args:\n      upstream:\n(?:        .*\n)+",
            INTL_DOH_UPSTREAMS_YAML.strip() + "\n\n",
            raw,
            count=1,
        )
    if _LEGACY_FORWARD_EASYMODNS in raw:
        raw = raw.replace(_LEGACY_FORWARD_EASYMODNS, INTL_DOH_EASYMODNS_YAML.strip())
    elif "  - tag: forward_easymosdns" in raw and "https://1.1.1.1/dns-query" not in raw:
        raw = re.sub(
            r"  - tag: forward_easymosdns\n    type: fast_forward\n    args:\n      upstream:\n(?:        .*\n)+",
            INTL_DOH_EASYMODNS_YAML.strip() + "\n\n",
            raw,
            count=1,
        )
    return raw


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
    raw = _patch_intl_doh_upstream(raw)
    raw = _inject_gfc_overlay(raw)
    _validate_easymosdns_schema(raw)

    MOSDNS_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    MOSDNS_CONFIG.write_text(raw, encoding="utf-8")
    return raw


def mosdns_config_ok(path: Path | None = None) -> tuple[bool, str]:
    cfg = path or MOSDNS_CONFIG
    if not cfg.is_file():
        return False, "missing config"
    try:
        _validate_easymosdns_schema(cfg.read_text(encoding="utf-8"))
    except RuntimeError as exc:
        return False, str(exc)

    ok_bin, bin_msg = mosdns_binary_ok()
    if not ok_bin:
        return False, bin_msg

    mosdns_bin = "/usr/local/bin/mosdns"
    if not Path(mosdns_bin).exists():
        from shutil import which

        found = which("mosdns")
        if not found:
            return False, "mosdns binary not found"
        mosdns_bin = found

    r = subprocess.run(
        ["timeout", "5", mosdns_bin, "start", "-c", str(cfg)],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(cfg.parent),
    )
    if r.returncode == 124:
        return True, bin_msg
    err = (r.stderr or r.stdout or "config check failed").strip()
    if "not defined" in err or "failed to init" in err:
        return False, err
    return False, err
