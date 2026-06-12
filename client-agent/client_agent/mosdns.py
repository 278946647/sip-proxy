from __future__ import annotations

from typing import Any

from .easymosdns_config import (
    MOSDNS_CONFIG,
    mosdns_config_ok,
    render_mosdns_config_file,
)


def render_mosdns_config(payload: dict[str, Any] | None = None) -> str:
    del payload  # easymosdns base + gfc block/china/global overlay
    return render_mosdns_config_file(try_download=False)
