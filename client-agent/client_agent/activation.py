from __future__ import annotations

import json
import os
from pathlib import Path

GFC_ETC = Path(os.environ.get("GFC_ETC", "/etc/gfc-client"))
ACTIVATION_FILE = Path(os.environ.get("ACTIVATION_FILE", "/etc/gfc-client/activation.b32"))
STATE_FILE = Path(
    os.environ.get(
        "STATE_FILE",
        "/opt/gfc-client/client-agent/state/client_state.json",
    )
)


def has_activation_file() -> bool:
    if not ACTIVATION_FILE.is_file():
        return False
    try:
        return bool(ACTIVATION_FILE.read_text(encoding="utf-8").strip())
    except OSError:
        return False


def is_line_activated() -> bool:
    if not STATE_FILE.is_file():
        return False
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return bool(data.get("client_token"))
    except (OSError, json.JSONDecodeError):
        return False
