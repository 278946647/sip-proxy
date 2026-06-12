from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Literal

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
MOSDNS_DIR = GFC_ETC / "mosdns"

ListName = Literal["block", "china", "global"]

LIST_FILES: dict[ListName, Path] = {
    "block": MOSDNS_DIR / "block.txt",
    "china": MOSDNS_DIR / "china.txt",
    "global": MOSDNS_DIR / "global.txt",
}

LEGACY_CHINA_FILE = MOSDNS_DIR / "cn-domains.txt"

DEFAULT_CHINA = [
    "baidu.com",
    "qq.com",
    "taobao.com",
    "alipay.com",
    "bilibili.com",
    "163.com",
    "126.com",
    "weixin.qq.com",
    "cn",
]

_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)*$", re.I)


def normalize_domain_line(line: str) -> str | None:
    raw = line.strip()
    if not raw or raw.startswith("#"):
        return None
    for prefix in ("full:", "domain:", "keyword:", "regexp:"):
        if raw.startswith(prefix):
            raw = raw[len(prefix) :].strip()
            break
    raw = raw.rstrip(".").lower()
    if not raw or raw.startswith("."):
        return None
    if raw == "cn" or _DOMAIN_RE.match(raw):
        return raw
    return None


def parse_domains_text(text: str) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for line in text.splitlines():
        domain = normalize_domain_line(line)
        if domain and domain not in seen:
            seen.add(domain)
            out.append(domain)
    return out


def read_list(name: ListName) -> list[str]:
    path = LIST_FILES[name]
    if not path.is_file():
        return []
    return parse_domains_text(path.read_text(encoding="utf-8"))


def write_list(name: ListName, domains: list[str]) -> Path:
    path = LIST_FILES[name]
    path.parent.mkdir(parents=True, exist_ok=True)
    header = {
        "block": "# 屏蔽列表：域名及子域名不解析（每行一个，支持 full:domain.com）",
        "china": "# 国内列表：走国内 DNS（223.5.5.5 等），兼容 easymosdns china 表",
        "global": "# 国际列表：走 8.8.8.8 / 1.1.1.1 等上游",
    }[name]
    body = "\n".join(domains) + ("\n" if domains else "")
    path.write_text(f"{header}\n{body}", encoding="utf-8")
    return path


def append_domains(name: ListName, domains: list[str]) -> list[str]:
    current = read_list(name)
    merged = parse_domains_text("\n".join(current + domains))
    write_list(name, merged)
    return merged


def export_list_text(name: ListName) -> str:
    return "\n".join(read_list(name)) + ("\n" if read_list(name) else "")


def import_list_text(name: ListName, text: str, *, replace: bool) -> list[str]:
    incoming = parse_domains_text(text)
    if replace:
        write_list(name, incoming)
        return incoming
    return append_domains(name, incoming)


def ensure_default_lists() -> None:
    MOSDNS_DIR.mkdir(parents=True, exist_ok=True)
    for name in ("block", "global"):
        if not LIST_FILES[name].is_file():
            write_list(name, [])

    if LIST_FILES["china"].is_file():
        return
    if LEGACY_CHINA_FILE.is_file():
        domains = parse_domains_text(LEGACY_CHINA_FILE.read_text(encoding="utf-8"))
        write_list("china", domains or DEFAULT_CHINA)
        return
    write_list("china", DEFAULT_CHINA)
