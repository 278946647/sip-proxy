from __future__ import annotations

import datetime as dt
import json
from typing import Any


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def ensure_utc(ts: dt.datetime | None) -> dt.datetime | None:
    """SQLite often returns naive UTC; normalize for comparisons."""
    if ts is None:
        return None
    if ts.tzinfo is None:
        return ts.replace(tzinfo=dt.timezone.utc)
    return ts.astimezone(dt.timezone.utc)


def seconds_ago(ts: dt.datetime | None, *, now: dt.datetime | None = None) -> float | None:
    if ts is None:
        return None
    ref = ensure_utc(now) or utc_now()
    return (ref - ensure_utc(ts)).total_seconds()


def parse_json_field(raw: str | None) -> Any | None:
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None
