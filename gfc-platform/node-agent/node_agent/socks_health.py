"""SOCKS reachability probes for DNS failover."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

HEALTH_FILE = "socks_dns_health.json"
FAILS_TO_DOWN = max(1, int(os.environ.get("GFC_SOCKS_DNS_FAIL_THRESHOLD", "2")))
PROBE_INTERVAL = max(10, int(os.environ.get("GFC_SOCKS_DNS_PROBE_SECONDS", "30")))
PROBE_TIMEOUT = max(3, int(os.environ.get("GFC_SOCKS_DNS_PROBE_TIMEOUT", "8")))

_last_probe_mono = 0.0
_last_result: dict[str, bool] = {}


def _health_path(state_dir: Path) -> Path:
    return state_dir / HEALTH_FILE


def load_dns_health(state_dir: Path) -> dict[str, bool]:
    path = _health_path(state_dir)
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        out = data.get("ok") or {}
        return {str(k): bool(v) for k, v in out.items()}
    except (OSError, json.JSONDecodeError, TypeError):
        return {}


def dns_health_changed(state_dir: Path, current: dict[str, bool]) -> bool:
    return load_dns_health(state_dir) != current


def _save_health(state_dir: Path, ok: dict[str, bool], streaks: dict[str, int]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    _health_path(state_dir).write_text(
        json.dumps(
            {"ok": ok, "fail_streak": streaks, "updated_at": int(time.time())},
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def _probe_socks(socks: dict[str, Any]) -> bool:
    if not shutil.which("curl"):
        return True
    host = (socks.get("host") or "").strip()
    port = int(socks.get("port") or 0)
    if not host or not port:
        return False
    user = (socks.get("username") or "").strip()
    pw = (socks.get("password") or "").strip()
    proxy = f"socks5://{host}:{port}"
    if user:
        proxy = f"socks5://{user}:{pw}@{host}:{port}"
    try:
        r = subprocess.run(
            [
                "curl",
                "-fsS",
                "--connect-timeout",
                str(PROBE_TIMEOUT),
                "-x",
                proxy,
                os.environ.get("GFC_SOCKS_PROBE_URL", "https://api.ipify.org"),
            ],
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT + 3,
        )
        return r.returncode == 0 and bool((r.stdout or "").strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def evaluate_socks_dns_health(payload: dict[str, Any], state_dir: Path) -> dict[str, bool]:
    """Return per-outbound-tag DNS-via-SOCKS health (False => use local DNS)."""
    global _last_probe_mono, _last_result

    rules = (payload.get("dataplane") or {}).get("rules") or []
    client_users = (payload.get("clientIngress") or {}).get("users") or []
    probe_targets: list[tuple[str, dict[str, Any]]] = []
    for idx, rule in enumerate(rules):
        tag = f"socks-{rule.get('lineId', idx)}"
        probe_targets.append((tag, rule.get("socks") or {}))
    for user in client_users:
        outbound = user.get("outbound") or {}
        if (outbound.get("mode") or "").strip().lower() != "socks":
            continue
        tag = f"client-{user.get('lineId')}"
        probe_targets.append((tag, outbound))

    if not probe_targets:
        return {}

    now = time.monotonic()
    if _last_result and now - _last_probe_mono < PROBE_INTERVAL:
        return dict(_last_result)

    path = _health_path(state_dir)
    streaks: dict[str, int] = {}
    if path.is_file():
        try:
            saved = json.loads(path.read_text(encoding="utf-8"))
            raw = saved.get("fail_streak") or {}
            streaks = {str(k): int(v) for k, v in raw.items()}
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            streaks = {}

    result: dict[str, bool] = {}
    for tag, socks in probe_targets:
        probe_ok = _probe_socks(socks)
        streak = streaks.get(tag, 0)
        if probe_ok:
            streaks[tag] = 0
            result[tag] = True
        else:
            streak += 1
            streaks[tag] = streak
            result[tag] = streak < FAILS_TO_DOWN

    _save_health(state_dir, result, streaks)
    _last_probe_mono = now
    _last_result = dict(result)
    return result


def format_dns_health_summary(ok: dict[str, bool]) -> str:
    if not ok:
        return "dns-health: n/a"
    parts = [f"{tag}={'socks-doh' if v else 'node-direct-doh'}" for tag, v in sorted(ok.items())]
    return "dns-health: " + ", ".join(parts)
