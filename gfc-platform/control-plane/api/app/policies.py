"""Field-level and resource-level authorization policies."""
from __future__ import annotations

from fastapi import HTTPException

from .models import ClientDevice
from .permissions import (
    CLIENT_CRITICAL_PATCH_FIELDS,
    LINE_CRITICAL_PATCH_FIELDS,
    NODE_CRITICAL_PATCH_FIELDS,
    OPERATOR_CLIENT_PATCH_FIELDS,
    OPERATOR_LINE_PATCH_FIELDS,
    OPERATOR_NODE_PATCH_FIELDS,
    normalize_role,
)
from .reverse_ssh import session_active
from .schemas import ClientDeviceUpdateIn, LineUpdateIn, NodeUpdateIn


def _forbidden_fields(role: str, data: dict[str, object], allowed: frozenset[str]) -> list[str]:
    if normalize_role(role) == "admin":
        return []
    return [k for k in data if k not in allowed]


def _raise_if_forbidden(role: str, forbidden: list[str], resource: str) -> None:
    if forbidden:
        raise HTTPException(
            403,
            f"permission denied: cannot modify {resource} fields: {', '.join(sorted(forbidden))}",
        )


def filter_line_update(role: str, body: LineUpdateIn) -> LineUpdateIn:
    data = body.model_dump(exclude_unset=True)
    forbidden = _forbidden_fields(role, data, OPERATOR_LINE_PATCH_FIELDS)
    _raise_if_forbidden(role, forbidden, "line")
    if normalize_role(role) != "admin":
        critical = [k for k in data if k in LINE_CRITICAL_PATCH_FIELDS]
        _raise_if_forbidden(role, critical, "line")
    if "is_enabled" in data:
        data["status"] = "active" if data["is_enabled"] else "inactive"
    return LineUpdateIn(**data)


def filter_node_update(role: str, body: NodeUpdateIn) -> NodeUpdateIn:
    data = body.model_dump(exclude_unset=True)
    forbidden = _forbidden_fields(role, data, OPERATOR_NODE_PATCH_FIELDS)
    _raise_if_forbidden(role, forbidden, "node")
    if normalize_role(role) != "admin":
        critical = [k for k in data if k in NODE_CRITICAL_PATCH_FIELDS]
        _raise_if_forbidden(role, critical, "node")
    return NodeUpdateIn(**data)


def filter_client_device_update(role: str, body: ClientDeviceUpdateIn) -> ClientDeviceUpdateIn:
    data = body.model_dump(exclude_unset=True)
    forbidden = _forbidden_fields(role, data, OPERATOR_CLIENT_PATCH_FIELDS)
    _raise_if_forbidden(role, forbidden, "client device")
    if normalize_role(role) != "admin":
        critical = [k for k in data if k in CLIENT_CRITICAL_PATCH_FIELDS]
        _raise_if_forbidden(role, critical, "client device")
    return ClientDeviceUpdateIn(**data)


def is_operator_deletable_client(device: ClientDevice, *, online: bool) -> bool:
    """三无离线：无线路 + 无会话 + 离线。"""
    if online:
        return False
    if device.line_id is not None:
        return False
    if session_active(device):
        return False
    return True


def assert_client_device_deletable(role: str, device: ClientDevice, *, online: bool) -> None:
    r = normalize_role(role)
    if r == "admin":
        return
    if r == "auditor":
        raise HTTPException(403, "permission denied")
    if r == "operator":
        if not is_operator_deletable_client(device, online=online):
            raise HTTPException(403, "只能删除无线路、无会话的离线客户端")
        return
    raise HTTPException(403, "permission denied")


def assert_line_code_refresh_allowed(role: str, *, rotate_uuid: bool) -> None:
    if rotate_uuid and normalize_role(role) != "admin":
        raise HTTPException(403, "permission denied: rotate_uuid requires admin")
