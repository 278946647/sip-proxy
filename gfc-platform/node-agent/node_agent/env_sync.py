from __future__ import annotations

import os
import re
from pathlib import Path

GFC_ENV = Path(os.environ.get("GFC_ETC", "/etc/gfc-node")) / "gfc.env"
_BOOTSTRAP_RE = re.compile(r"^BOOTSTRAP_TOKEN=.*$", re.MULTILINE)


def read_bootstrap_token() -> str | None:
    if not GFC_ENV.is_file():
        return None
    for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
        if line.startswith("BOOTSTRAP_TOKEN="):
            return line.split("=", 1)[1].strip()
    return None


def sync_bootstrap_token(token: str | None) -> str | None:
    """Align /etc/gfc-node/gfc.env with control-plane bootstrap (for reinstall/repair)."""
    token = (token or "").strip()
    if not token or not GFC_ENV.is_file():
        return None
    current = read_bootstrap_token()
    if current == token:
        return None
    text = GFC_ENV.read_text(encoding="utf-8")
    if _BOOTSTRAP_RE.search(text):
        text = _BOOTSTRAP_RE.sub(f"BOOTSTRAP_TOKEN={token}", text, count=1)
    else:
        text = text.rstrip() + f"\nBOOTSTRAP_TOKEN={token}\n"
    GFC_ENV.write_text(text, encoding="utf-8")
    return f"bootstrap token synced -> {token[:8]}..."
