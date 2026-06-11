#!/usr/bin/env python3
"""修补服务器上过旧的 singbox.py（去掉 1.13.4 不支持的 timeout 字段）。

sudo python3 /var/socks/deploy/node/patch-singbox-py.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

TARGETS = [
    Path("/var/socks/node-agent/node_agent/singbox.py"),
    Path("/opt/gfc-node/node-agent/node_agent/singbox.py"),
]


def patch(text: str) -> tuple[str, bool]:
    orig = text
    text = re.sub(r'^\s*"timeout":\s*"[^"]+",\s*\n', "", text, flags=re.MULTILINE)
    text = re.sub(r'^\s*ob\["connect_timeout"\]\s*=\s*"[^"]+"\s*\n', "", text, flags=re.MULTILINE)
    text = re.sub(
        r"\s*if proxy_dns_ok and fallback_enabled:.*?dns_rules\.append\(dns_rule\)",
        "",
        text,
        flags=re.DOTALL,
    )
    return text, text != orig


def main() -> int:
    n = 0
    for p in TARGETS:
        if not p.is_file():
            continue
        new, changed = patch(p.read_text(encoding="utf-8"))
        if changed:
            p.write_text(new, encoding="utf-8", newline="\n")
            print("patched", p)
            n += 1
        else:
            print("ok (no change)", p)
    if n == 0 and not any(p.is_file() for p in TARGETS):
        print("ERROR: singbox.py not found")
        return 1
    print("done — run: sudo bash /var/socks/deploy/node/force-reapply.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
