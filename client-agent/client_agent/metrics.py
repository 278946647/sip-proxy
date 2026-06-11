from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any


def _read_proc_stat_cpu() -> tuple[int, int]:
    with open("/proc/stat", "r", encoding="utf-8") as f:
        line = f.readline()
    parts = line.split()
    if len(parts) < 5:
        return 0, 0
    nums = [int(x) for x in parts[1:]]
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    total = sum(nums)
    return total, idle


def _cpu_percent() -> float:
    t1, i1 = _read_proc_stat_cpu()
    time.sleep(0.15)
    t2, i2 = _read_proc_stat_cpu()
    dt = t2 - t1
    di = i2 - i1
    if dt <= 0:
        return 0.0
    return max(0.0, min(100.0, (1.0 - di / dt) * 100.0))


def _memory_mb() -> tuple[int, int]:
    mem_total = mem_avail = 0
    with open("/proc/meminfo", "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                mem_total = int(line.split()[1]) // 1024
            elif line.startswith("MemAvailable:"):
                mem_avail = int(line.split()[1]) // 1024
    used = max(0, mem_total - mem_avail)
    return used, mem_total


def _connection_count() -> int:
    try:
        r = subprocess.run(
            ["ss", "-Htan"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if r.returncode == 0:
            return len([ln for ln in (r.stdout or "").splitlines() if ln.strip()])
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        with open("/proc/net/sockstat", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("TCP:"):
                    parts = line.split()
                    if len(parts) >= 3:
                        return int(parts[2])
    except OSError:
        pass
    return 0


def _iface_bytes(iface: str | None) -> tuple[int, int]:
    rx = tx = 0
    try:
        with open("/proc/net/dev", "r", encoding="utf-8") as f:
            for line in f:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                name = name.strip()
                if iface and name != iface:
                    continue
                if not iface and name in ("lo",):
                    continue
                cols = rest.split()
                if len(cols) >= 9:
                    rx += int(cols[0])
                    tx += int(cols[8])
                if iface:
                    break
    except OSError:
        pass
    return rx, tx


class _RateTracker:
    def __init__(self) -> None:
        self._last: tuple[float, int, int] | None = None
        self.peak_up = 0.0
        self.peak_down = 0.0

    def sample(self, iface: str | None) -> tuple[float, float, float, float]:
        now = time.time()
        rx, tx = _iface_bytes(iface)
        up = down = 0.0
        if self._last:
            dt = now - self._last[0]
            if dt > 0:
                down = max(0.0, (rx - self._last[1]) * 8 / dt / 1_000_000)
                up = max(0.0, (tx - self._last[2]) * 8 / dt / 1_000_000)
        self._last = (now, rx, tx)
        self.peak_up = max(self.peak_up, up)
        self.peak_down = max(self.peak_down, down)
        return up, down, self.peak_up, self.peak_down


_RATE = _RateTracker()


def _systemd_active(unit: str) -> dict[str, Any]:
    try:
        r = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=5,
        )
        active = r.stdout.strip() == "active"
        return {
            "active": active,
            "status": r.stdout.strip(),
            "message": None if active else (r.stderr.strip() or r.stdout.strip()),
        }
    except Exception as e:  # noqa: BLE001
        return {"active": False, "status": "unknown", "message": str(e)}


def collect_metrics(
    server_url: str,
    client_reachable: bool,
    lan_iface: str | None = None,
) -> dict[str, Any]:
    mem_used, mem_total = _memory_mb()
    up, down, peak_up, peak_down = _RATE.sample(lan_iface or os.environ.get("GFC_LAN_IFACE"))
    cpu_cores = os.cpu_count() or 1

    return {
        "control_plane_reachable": client_reachable,
        "cpu_percent": round(_cpu_percent(), 1),
        "cpu_cores": cpu_cores,
        "memory_used_mb": mem_used,
        "memory_total_mb": mem_total,
        "connection_count": _connection_count(),
        "upload_mbps": round(up, 2),
        "download_mbps": round(down, 2),
        "upload_peak_mbps": round(peak_up, 2),
        "download_peak_mbps": round(peak_down, 2),
        "services": {
            "gfc-client-agent": {"active": True, "status": "running"},
            "sing-box": _systemd_active("gfc-client-sing-box.service"),
            "mosdns": _systemd_active("gfc-mosdns.service"),
        },
        "sing_box_installed": shutil.which("sing-box") is not None,
        "mosdns_installed": shutil.which("mosdns") is not None,
    }


def write_status_snapshot(metrics: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2), encoding="utf-8")
