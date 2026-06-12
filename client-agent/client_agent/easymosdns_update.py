from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Literal

from .apply import apply_dns_config
from .dns_lists import import_list_text, parse_domains_text

Source = Literal["github", "cdn"]

GITHUB_BASE = "https://raw.githubusercontent.com/pmkol/easymosdns/rules"
CDN_BASE = "https://fastly.jsdelivr.net/gh/pmkol/easymosdns@rules"
BOOTSTRAP_DNS = ("223.5.5.5", "119.29.29.29", "8.8.8.8", "1.1.1.1")

RULE_FILES = (
    "china_domain_list.txt",
    "gfw_domain_list.txt",
    "cdn_domain_list.txt",
    "ad_domain_list.txt",
    "china_ip_list.txt",
    "gfw_ip_list.txt",
)

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
EASYMODNS_RULES_DIR = GFC_ETC / "mosdns" / "easymosdns" / "rules"


def _fetch_curl(url: str, timeout: int = 180) -> bytes:
    dns_args: list[str] = []
    for addr in BOOTSTRAP_DNS:
        dns_args.extend(["--dns-servers", addr])
    cmd = [
        "curl",
        "-fsSL",
        "--connect-timeout",
        "20",
        "--max-time",
        str(timeout),
        *dns_args,
        url,
    ]
    r = subprocess.run(cmd, capture_output=True, check=False)
    if r.returncode == 0 and r.stdout:
        return r.stdout
    err = (r.stderr or b"").decode("utf-8", errors="replace").strip()
    raise RuntimeError(err or f"curl failed ({r.returncode})")


def _fetch(url: str, timeout: int = 120) -> bytes:
    if shutil.which("curl"):
        try:
            return _fetch_curl(url, timeout=timeout)
        except RuntimeError:
            pass
    req = urllib.request.Request(url, headers={"User-Agent": "gfc-client-agent/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.URLError as exc:
        raise RuntimeError(f"download failed: {exc}") from exc


def _md5_hex(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def _load_md5_reference(text: str) -> dict[str, str]:
    refs: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            refs[parts[1]] = parts[0].lower()
    return refs


def update_easymosdns_rules(source: Source = "github") -> dict:
    base = GITHUB_BASE if source == "github" else CDN_BASE
    label = "GitHub (update)" if source == "github" else "CDN (update-cdn)"

    md5_raw = _fetch(f"{base}/md5_hash_list.txt").decode("utf-8", errors="replace")
    if "txt" not in md5_raw:
        raise RuntimeError(f"{label}: 无法下载 md5_hash_list.txt")

    md5_ref = _load_md5_reference(md5_raw)
    if not md5_ref:
        raise RuntimeError(f"{label}: md5_hash_list.txt 格式无效")

    EASYMODNS_RULES_DIR.mkdir(parents=True, exist_ok=True)

    saved: dict[str, int] = {}
    errors: list[str] = []

    for name in RULE_FILES:
        url = f"{base}/{name}"
        try:
            raw = _fetch(url)
        except RuntimeError as exc:
            errors.append(f"{name}: {exc}")
            continue

        digest = _md5_hex(raw)
        expected = md5_ref.get(name)
        if expected and digest != expected:
            errors.append(f"{name}: MD5 校验失败 (got {digest}, want {expected})")
            continue
        if not expected and digest not in md5_ref.values():
            errors.append(f"{name}: MD5 不在参考列表 ({digest})")
            continue

        (EASYMODNS_RULES_DIR / name).write_bytes(raw)
        saved[name] = len(raw)

    if not saved:
        raise RuntimeError(f"{label}: 无有效规则文件" + (f"; {'; '.join(errors)}" if errors else ""))

    counts = _import_into_gfc_lists()
    ok, apply_msg = apply_dns_config()
    restart_msg = _restart_mosdns()

    return {
        "ok": ok,
        "source": source,
        "label": label,
        "saved_files": saved,
        "imported": counts,
        "errors": errors,
        "apply_message": apply_msg,
        "mosdns_restarted": restart_msg,
    }


def _import_into_gfc_lists() -> dict[str, int]:
    def read_rule(name: str) -> str:
        path = EASYMODNS_RULES_DIR / name
        if not path.is_file():
            return ""
        return path.read_text(encoding="utf-8", errors="replace")

    block = import_list_text("block", read_rule("ad_domain_list.txt"), replace=True)
    global_list = import_list_text("global", read_rule("gfw_domain_list.txt"), replace=True)

    china_domains = parse_domains_text(read_rule("china_domain_list.txt"))
    cdn_domains = parse_domains_text(read_rule("cdn_domain_list.txt"))
    merged_china: list[str] = []
    seen: set[str] = set()
    for d in china_domains + cdn_domains:
        if d not in seen:
            seen.add(d)
            merged_china.append(d)
    import_list_text("china", "\n".join(merged_china), replace=True)

    return {
        "block": len(block),
        "china": len(merged_china),
        "global": len(global_list),
    }


def _restart_mosdns() -> str:
    if not Path("/bin/systemctl").exists():
        return "no systemd"
    r = subprocess.run(
        ["systemctl", "restart", "gfc-mosdns.service"],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode == 0:
        return "restarted"
    return r.stderr or r.stdout or "failed"
