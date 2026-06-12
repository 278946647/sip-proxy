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


def code_kind(payload: dict[str, Any]) -> str:
    """platform = only control-plane URLs; line = bind client line (default for v1)."""
    kind = (payload.get("kind") or "").strip().lower()
    if kind in ("platform", "line"):
        return kind
    if payload.get("lineId"):
        return "line"
    if payload.get("server") and not payload.get("lineId"):
        return "platform"
    return "line"


def is_line_activation_payload(payload: dict[str, Any]) -> bool:
    return code_kind(payload) == "line"


def is_platform_payload(payload: dict[str, Any]) -> bool:
    return code_kind(payload) == "platform"
