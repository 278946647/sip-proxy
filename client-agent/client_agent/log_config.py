from __future__ import annotations

import os
from pathlib import Path
from typing import Literal

GFC_ENV = Path(os.environ.get("GFC_ENV_FILE", "/etc/gfc-client/gfc.env"))

SingboxLogLevel = Literal["error", "warn", "info", "debug"]
VALID_LEVELS = ("error", "warn", "info", "debug")


def _read_env_key(key: str) -> str:
    val = os.environ.get(key, "").strip()
    if val:
        return val
    if GFC_ENV.is_file():
        prefix = f"{key}="
        for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith(prefix):
                return line.split("=", 1)[1].strip()
    return ""


def read_verbose_log() -> bool:
    return _read_env_key("GFC_VERBOSE_LOG").lower() in ("1", "true", "yes", "on")


def read_singbox_log_level() -> SingboxLogLevel:
    if read_verbose_log():
        level = _read_env_key("GFC_SINGBOX_LOG_LEVEL").lower()
        if level in VALID_LEVELS:
            return level  # type: ignore[return-value]
        return "info"
    level = _read_env_key("GFC_SINGBOX_LOG_LEVEL").lower()
    if level in VALID_LEVELS:
        return level  # type: ignore[return-value]
    return "error"


def _write_env_key(key: str, value: str) -> None:
    lines: list[str] = []
    replaced = False
    prefix = f"{key}="
    if GFC_ENV.is_file():
        for line in GFC_ENV.read_text(encoding="utf-8").splitlines():
            if line.startswith(prefix):
                lines.append(f"{key}={value}")
                replaced = True
            else:
                lines.append(line)
    if not replaced:
        lines.append(f"{key}={value}")
    GFC_ENV.parent.mkdir(parents=True, exist_ok=True)
    GFC_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(GFC_ENV, 0o600)


def write_verbose_log(enabled: bool) -> None:
    _write_env_key("GFC_VERBOSE_LOG", "1" if enabled else "0")


def write_singbox_log_level(level: SingboxLogLevel) -> None:
    if level not in VALID_LEVELS:
        raise ValueError(f"log level must be one of {VALID_LEVELS}")
    _write_env_key("GFC_SINGBOX_LOG_LEVEL", level)


def logging_status() -> dict[str, str | bool]:
    return {
        "level": read_singbox_log_level(),
        "verbose": read_verbose_log(),
    }
