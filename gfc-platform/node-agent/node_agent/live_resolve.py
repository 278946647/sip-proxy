"""Per-line live_catalog DoH pre-resolve via SOCKS/direct vantage (§4A)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

RESOLVE_INTERVAL = max(60, int(os.environ.get("GFC_LIVE_RESOLVE_SECONDS", "300")))
RESOLVE_TIMEOUT = max(5, int(os.environ.get("GFC_LIVE_RESOLVE_TIMEOUT", "12")))
RESOLVE_DIR = Path(os.environ.get("GFC_LIVE_RESOLVE_DIR", "/var/lib/gfc-node/live_resolve"))

_last_resolve_mono = 0.0
_last_catalog_epoch = ""
_last_task_epochs: dict[int, str] = {}


def _line_cache_path(line_id: int) -> Path:
    return RESOLVE_DIR / f"line-{line_id}.json"


def load_line_cache(line_id: int) -> dict[str, Any] | None:
    path = _line_cache_path(line_id)
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return None


def save_line_cache(line_id: int, data: dict[str, Any]) -> None:
    RESOLVE_DIR.mkdir(parents=True, exist_ok=True)
    _line_cache_path(line_id).write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def resolve_changed(results: list[dict[str, Any]]) -> bool:
    for item in results:
        line_id = int(item.get("lineId") or 0)
        if line_id <= 0:
            continue
        prev = load_line_cache(line_id) or {}
        if prev.get("cidrs") != item.get("cidrs"):
            return True
        if prev.get("catalogEpoch") != item.get("catalogEpoch"):
            return True
    return False


def _socks_proxy_url(outbound: dict[str, Any]) -> str | None:
    mode = (outbound.get("mode") or "").strip().lower()
    if mode != "socks":
        return None
    host = (outbound.get("host") or "").strip()
    port = int(outbound.get("port") or 0)
    if not host or not port:
        return None
    user = (outbound.get("username") or "").strip()
    pw = (outbound.get("password") or "").strip()
    if user:
        return f"socks5h://{user}:{pw}@{host}:{port}"
    return f"socks5h://{host}:{port}"


def _doh_json_a_records(domain: str, *, proxy: str | None, doh_url: str) -> list[str]:
    if not shutil.which("curl"):
        return []
    domain = domain.strip().lower().rstrip(".")
    if not domain:
        return []
    url = f"{doh_url}?name={domain}&type=A"
    cmd = [
        "curl",
        "-fsS",
        "--connect-timeout",
        str(RESOLVE_TIMEOUT),
        "-H",
        "accept: application/dns-json",
        url,
    ]
    if proxy:
        cmd[1:1] = ["-x", proxy]
    try:
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=RESOLVE_TIMEOUT + 3,
        )
        if r.returncode != 0:
            return []
        data = json.loads(r.stdout or "{}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, TypeError, ValueError):
        return []
    ips: list[str] = []
    seen: set[str] = set()
    for ans in data.get("Answer") or []:
        if not isinstance(ans, dict):
            continue
        if str(ans.get("type")) not in ("1", "A"):
            continue
        ip = str(ans.get("data") or "").strip()
        if ip and ip not in seen:
            seen.add(ip)
            ips.append(ip)
    return ips


def _outbound_healthy(detour_tag: str, socks_dns_ok: dict[str, bool]) -> bool:
    if detour_tag == "direct":
        return True
    if not socks_dns_ok:
        return True
    return bool(socks_dns_ok.get(detour_tag, True))


def _resolve_task(
    task: dict[str, Any],
    *,
    socks_dns_ok: dict[str, bool],
    doh_url: str,
    force: bool,
) -> dict[str, Any]:
    line_id = int(task.get("lineId") or 0)
    detour_tag = str(task.get("detourTag") or "").strip()
    outbound = task.get("outbound") or {}
    egress_hint = str(task.get("egressHint") or "").strip()
    catalog_epoch = str(task.get("catalogEpoch") or "")
    domains = list(task.get("domains") or [])
    static_cidrs = list(task.get("staticCidrs") or [])

    base = {
        "lineId": line_id,
        "detourTag": detour_tag,
        "egressHint": egress_hint,
        "catalogEpoch": catalog_epoch,
        "resolvedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    if not _outbound_healthy(detour_tag, socks_dns_ok):
        result = {
            **base,
            "cidrs": static_cidrs,
            "skippedUnhealthy": True,
            "usedFallbackVantage": False,
        }
        save_line_cache(line_id, result)
        return result

    proxy = _socks_proxy_url(outbound) if detour_tag != "direct" else None
    if detour_tag != "direct" and not proxy:
        result = {
            **base,
            "cidrs": static_cidrs,
            "skippedUnhealthy": True,
            "usedFallbackVantage": True,
        }
        save_line_cache(line_id, result)
        return result

    resolved_ips: list[str] = []
    seen_ip: set[str] = set()
    for domain in domains:
        for ip in _doh_json_a_records(domain, proxy=proxy, doh_url=doh_url):
            if ip not in seen_ip:
                seen_ip.add(ip)
                resolved_ips.append(ip)

    cidrs: list[str] = []
    seen_cidr: set[str] = set()
    for c in static_cidrs:
        c = str(c).strip()
        if c and c not in seen_cidr:
            seen_cidr.add(c)
            cidrs.append(c)
    for ip in resolved_ips:
        cidr = f"{ip}/32"
        if cidr not in seen_cidr:
            seen_cidr.add(cidr)
            cidrs.append(cidr)

    result = {
        **base,
        "cidrs": cidrs,
        "skippedUnhealthy": False,
        "usedFallbackVantage": False,
    }
    save_line_cache(line_id, result)
    return result


def _should_run_now(
    catalog: dict[str, Any],
    socks_dns_ok: dict[str, bool],
) -> tuple[bool, bool]:
    """Return (run_now, force_immediate)."""
    global _last_resolve_mono, _last_catalog_epoch, _last_task_epochs

    epoch = str(catalog.get("catalogEpoch") or "")
    tasks = catalog.get("tasks") or []
    if not tasks:
        return False, False

    force = epoch != _last_catalog_epoch
    if not force:
        for task in tasks:
            line_id = int(task.get("lineId") or 0)
            task_epoch = str(task.get("catalogEpoch") or "")
            if _last_task_epochs.get(line_id) != task_epoch:
                force = True
                break

    now = time.monotonic()
    if not force and now - _last_resolve_mono < RESOLVE_INTERVAL:
        return False, False
    return True, force


def maybe_run_live_resolve(
    payload: dict[str, Any],
    socks_dns_ok: dict[str, bool],
) -> list[dict[str, Any]]:
    global _last_resolve_mono, _last_catalog_epoch, _last_task_epochs

    catalog = payload.get("liveCatalog") or {}
    tasks = catalog.get("tasks") or []
    if not tasks:
        return []

    run, force = _should_run_now(catalog, socks_dns_ok)
    if not run:
        return []

    doh_url = str(catalog.get("dohUrl") or "https://1.1.1.1/dns-query").strip()
    results: list[dict[str, Any]] = []
    for task in tasks:
        if (task.get("liveMode") or "").strip() != "live_catalog":
            continue
        result = _resolve_task(task, socks_dns_ok=socks_dns_ok, doh_url=doh_url, force=force)
        results.append(result)
        line_id = int(task.get("lineId") or 0)
        _last_task_epochs[line_id] = str(task.get("catalogEpoch") or "")

    _last_resolve_mono = time.monotonic()
    _last_catalog_epoch = str(catalog.get("catalogEpoch") or "")
    return results


def format_live_resolve_summary(results: list[dict[str, Any]]) -> str:
    if not results:
        return "live-resolve: n/a"
    parts = []
    for item in results:
        line_id = item.get("lineId")
        n = len(item.get("cidrs") or [])
        if item.get("skippedUnhealthy"):
            parts.append(f"line-{line_id}=skipped")
        else:
            parts.append(f"line-{line_id}={n}cidrs")
    return "live-resolve: " + ", ".join(parts)
