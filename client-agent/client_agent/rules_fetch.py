from __future__ import annotations

import os
import shutil
from pathlib import Path

from .easymosdns_fetch import fetch

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
RULES_DIR = GFC_ETC / "rules"
BUNDLE_RULES_DIR = Path(__file__).resolve().parent.parent / "deploy" / "rules"

META_RULES_BASE = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo"

# tag, local filename, remote path under sing/geo/
RULE_SPECS: list[tuple[str, str, str]] = [
    ("geosite-cn", "geosite-cn.srs", "geosite/cn.srs"),
    ("geoip-cn", "geoip-cn.srs", "geoip/cn.srs"),
    ("geosite-geolocation-!cn", "geosite-geolocation-not-cn.srs", "geosite/geolocation-!cn.srs"),
]


def _remote_url(remote_path: str) -> str:
    return f"{META_RULES_BASE}/{remote_path}"


def local_rules_available() -> bool:
    return all((RULES_DIR / filename).is_file() for _tag, filename, _remote in RULE_SPECS)


def _copy_bundle_rules() -> list[str]:
    copied: list[str] = []
    if not BUNDLE_RULES_DIR.is_dir():
        return copied
    RULES_DIR.mkdir(parents=True, exist_ok=True)
    for _tag, filename, _remote in RULE_SPECS:
        src = BUNDLE_RULES_DIR / filename
        dst = RULES_DIR / filename
        if src.is_file() and (not dst.is_file() or dst.stat().st_size == 0):
            shutil.copy2(src, dst)
            copied.append(filename)
    return copied


def ensure_local_rules(*, try_download: bool = True) -> tuple[bool, list[str]]:
    """Ensure meta-rules .srs files exist under /etc/gfc-client/rules."""
    messages: list[str] = []
    copied = _copy_bundle_rules()
    if copied:
        messages.append(f"copied bundle rules: {', '.join(copied)}")

    missing = [
        (filename, remote)
        for _tag, filename, remote in RULE_SPECS
        if not (RULES_DIR / filename).is_file()
    ]
    if not missing:
        return True, messages

    if not try_download:
        return False, messages + [f"missing: {', '.join(name for name, _ in missing)}"]

    RULES_DIR.mkdir(parents=True, exist_ok=True)
    errors: list[str] = []
    for filename, remote in missing:
        url = _remote_url(remote)
        try:
            data = fetch(url, timeout=180)
            if len(data) < 64:
                raise RuntimeError("file too small")
            (RULES_DIR / filename).write_bytes(data)
            messages.append(f"downloaded {filename}")
        except RuntimeError as exc:
            errors.append(f"{filename}: {exc}")

    ok = local_rules_available()
    if errors:
        messages.extend(errors)
    return ok, messages


def rule_set_entries(*, allow_remote: bool = False) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    for tag, filename, remote in RULE_SPECS:
        path = RULES_DIR / filename
        if path.is_file():
            entries.append(
                {
                    "type": "local",
                    "tag": tag,
                    "format": "binary",
                    "path": str(path),
                }
            )
        elif allow_remote:
            entries.append(
                {
                    "type": "remote",
                    "tag": tag,
                    "format": "binary",
                    "url": _remote_url(remote),
                    "download_detour": "direct",
                    "update_interval": "1d",
                }
            )
    return entries


def try_update_rules(*, try_download: bool = True) -> dict[str, object]:
    """Refresh local rule files; best-effort when proxy is available."""
    ok, messages = ensure_local_rules(try_download=try_download)
    if not ok or not try_download:
        return {"ok": ok, "messages": messages, "updated": []}

    updated: list[str] = []
    errors: list[str] = []
    RULES_DIR.mkdir(parents=True, exist_ok=True)
    for _tag, filename, remote in RULE_SPECS:
        url = _remote_url(remote)
        try:
            data = fetch(url, timeout=180)
            if len(data) < 64:
                raise RuntimeError("file too small")
            dst = RULES_DIR / filename
            if dst.is_file() and dst.read_bytes() == data:
                continue
            dst.write_bytes(data)
            updated.append(filename)
        except RuntimeError as exc:
            errors.append(f"{filename}: {exc}")

    return {
        "ok": local_rules_available(),
        "updated": updated,
        "messages": messages,
        "errors": errors,
    }
