from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

GFC_ENV = Path(os.environ.get("GFC_ENV_FILE", "/etc/gfc-client/gfc.env"))

RoutingMode = Literal["split", "global"]


def read_routing_mode() -> RoutingMode:
    val = os.environ.get("GFC_ROUTING_MODE", "").strip().lower()
    if val in ("split", "global"):
        return val  # type: ignore[return-value]
    if GFC_ENV.is_file():
        for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("GFC_ROUTING_MODE="):
                mode = line.split("=", 1)[1].strip().lower()
                if mode in ("split", "global"):
                    return mode  # type: ignore[return-value]
    return "split"


def write_routing_mode(mode: RoutingMode) -> None:
    if mode not in ("split", "global"):
        raise ValueError("routing mode must be split or global")
    lines: list[str] = []
    replaced = False
    if GFC_ENV.is_file():
        for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
            if line.startswith("GFC_ROUTING_MODE="):
                lines.append(f"GFC_ROUTING_MODE={mode}")
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        lines.append(f"GFC_ROUTING_MODE={mode}")
    GFC_ENV.parent.mkdir(parents=True, exist_ok=True)
    GFC_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(GFC_ENV, 0o600)
