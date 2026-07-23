"""Platform RBAC: admin (super), operator (limited write), auditor (read-only)."""
from __future__ import annotations

from typing import Literal

from fastapi import HTTPException

from .models import PlatformUser
from .schemas import UserOut, UserPermissionsOut

Role = Literal["admin", "operator", "auditor"]
Action = Literal[
    "read",
    "read_sensitive",
    "write_safe",
    "write_critical",
    "delete",
    "admin",
]

VALID_ROLES: frozenset[str] = frozenset({"admin", "operator", "auditor"})

ROLE_ACTIONS: dict[str, frozenset[Action]] = {
    "admin": frozenset(
        {
            "read",
            "read_sensitive",
            "write_safe",
            "write_critical",
            "delete",
            "admin",
        }
    ),
    "operator": frozenset({"read", "read_sensitive", "write_safe"}),
    "auditor": frozenset({"read"}),
}

OPERATOR_LINE_PATCH_FIELDS = frozenset(
    {
        "remark",
        "socks_remark",
        "name",
        "country",
        "bandwidth_mbps",
        "is_enabled",
        "status",
        "socks_udp_over_tcp",
    }
)

OPERATOR_NODE_PATCH_FIELDS = frozenset({"name", "region", "country"})

OPERATOR_CLIENT_PATCH_FIELDS = frozenset({"name", "routing_scheme", "is_active"})

LINE_CRITICAL_PATCH_FIELDS = frozenset(
    {"node_id", "source_cidrs", "socks_profile_id", "flow_stats_enabled"}
)

NODE_CRITICAL_PATCH_FIELDS = frozenset(
    {"connect_mode", "vpn_config", "static_routes", "is_active"}
)

CLIENT_CRITICAL_PATCH_FIELDS = frozenset({"line_id", "reverse_ssh_port"})

MENU_KEYS_BY_ROLE: dict[str, list[str]] = {
    "admin": [
        "dashboard",
        "nodes",
        "lines",
        "client-devices",
        "traffic",
        "health",
        "proxies",
        "settings",
        "users",
        "logs",
        "help",
    ],
    "operator": [
        "dashboard",
        "nodes",
        "lines",
        "client-devices",
        "traffic",
        "health",
        "proxies",
        "logs",
        "help",
    ],
    "auditor": [
        "dashboard",
        "nodes",
        "lines",
        "client-devices",
        "traffic",
        "health",
        "proxies",
        "logs",
        "help",
    ],
}


def normalize_role(role: str | None) -> str:
    r = (role or "").strip().lower()
    if r not in VALID_ROLES:
        return "operator"
    return r


def role_allows(role: str | None, action: Action) -> bool:
    return action in ROLE_ACTIONS.get(normalize_role(role), frozenset())


def can_remote_access(role: str | None) -> bool:
    return normalize_role(role) in {"admin", "operator"}


def permissions_payload(role: str | None) -> UserPermissionsOut:
    r = normalize_role(role)
    actions = sorted(ROLE_ACTIONS.get(r, frozenset()))
    return UserPermissionsOut(
        actions=actions,
        menus=MENU_KEYS_BY_ROLE.get(r, MENU_KEYS_BY_ROLE["operator"]),
        can_remote_access=can_remote_access(r),
        can_delete_structural=r == "admin",
        can_write_traffic_billing=r == "admin",
    )


def user_out(user: PlatformUser) -> UserOut:
    return UserOut(
        id=user.id,
        username=user.username,
        role=normalize_role(user.role),
        is_active=user.is_active,
        created_at=user.created_at,
        permissions=permissions_payload(user.role),
    )


def assert_valid_role(role: str) -> str:
    r = role.strip().lower()
    if r not in VALID_ROLES:
        raise HTTPException(400, f"invalid role: {role}")
    return r


def assert_role_action(role: str | None, action: Action) -> None:
    if not role_allows(role, action):
        raise HTTPException(403, "permission denied")
