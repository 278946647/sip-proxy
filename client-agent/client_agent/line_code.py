from __future__ import annotations

import base64
import json
from typing import Any


def decode_line_code(code: str) -> dict[str, Any]:
    normalized = code.strip().upper().replace(" ", "").replace("-", "")
    pad = (-len(normalized)) % 8
    raw = base64.b32decode(normalized + ("=" * pad))
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("line code must decode to a JSON object")
    return data


def read_activation_file(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read().strip()
    if not raw:
        raise ValueError("activation file is empty")
    return decode_line_code(raw)
