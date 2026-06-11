from __future__ import annotations

from typing import Any

# Legacy agents reported nftables systemd status; GFC loads rules via `nft -f` instead.
_STRIP_SERVICES = frozenset({"nftables"})


def sanitize_last_metrics(
    raw: dict[str, Any] | None,
    *,
    connect_mode: str | None = None,
) -> dict[str, Any] | None:
    if not raw or not isinstance(raw, dict):
        return raw
    out = dict(raw)
    services = out.get("services")
    if not isinstance(services, dict):
        return out
    cleaned = {
        k: v for k, v in services.items() if k not in _STRIP_SERVICES
    }
    if (connect_mode or "ethernet") != "openvpn":
        cleaned.pop("openvpn-backbone", None)
    out["services"] = cleaned
    return out
