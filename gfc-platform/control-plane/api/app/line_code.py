"""Line activation payload encoding (JSON → Base32 for device flash)."""
from __future__ import annotations

import base64
import json
from typing import Any


def encode_line_code(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.b32encode(raw).decode("ascii").rstrip("=")


def decode_line_code(code: str) -> dict[str, Any]:
    normalized = code.strip().upper().replace(" ", "").replace("-", "")
    pad = (-len(normalized)) % 8
    raw = base64.b32decode(normalized + ("=" * pad))
    data = json.loads(raw.decode("utf-8"))
    if not isinstance(data, dict):
        raise ValueError("line code must decode to a JSON object")
    return data
