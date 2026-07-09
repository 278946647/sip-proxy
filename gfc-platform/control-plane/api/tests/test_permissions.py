"""RBAC unit tests for platform permissions."""
from __future__ import annotations

import datetime as dt
import unittest

from app.models import ClientDevice
from app.permissions import role_allows, can_remote_access, VALID_ROLES
from app.policies import (
    filter_line_update,
    is_operator_deletable_client,
)
from app.reverse_ssh import session_active
from app.schemas import LineUpdateIn


class PermissionsTest(unittest.TestCase):
    def test_roles(self) -> None:
        self.assertEqual(VALID_ROLES, frozenset({"admin", "operator", "auditor"}))

    def test_admin_has_delete(self) -> None:
        self.assertTrue(role_allows("admin", "delete"))

    def test_operator_no_delete(self) -> None:
        self.assertFalse(role_allows("operator", "delete"))

    def test_auditor_read_only(self) -> None:
        self.assertTrue(role_allows("auditor", "read"))
        self.assertFalse(role_allows("auditor", "write_safe"))

    def test_remote_access(self) -> None:
        self.assertTrue(can_remote_access("operator"))
        self.assertFalse(can_remote_access("auditor"))

    def test_operator_line_patch_whitelist(self) -> None:
        body = LineUpdateIn(remark="x", node_id=99)
        with self.assertRaises(Exception):
            filter_line_update("operator", body)

    def test_operator_deletable_client(self) -> None:
        device = ClientDevice(
            id=1,
            device_key="k",
            name="d",
            line_id=None,
            reverse_ssh_session_expires_at=None,
        )
        self.assertTrue(is_operator_deletable_client(device, online=False))
        self.assertFalse(is_operator_deletable_client(device, online=True))

    def test_operator_not_deletable_with_line(self) -> None:
        device = ClientDevice(
            id=1,
            device_key="k",
            name="d",
            line_id=5,
            reverse_ssh_session_expires_at=None,
        )
        self.assertFalse(is_operator_deletable_client(device, online=False))

    def test_operator_not_deletable_with_session(self) -> None:
        device = ClientDevice(
            id=1,
            device_key="k",
            name="d",
            line_id=None,
            reverse_ssh_session_expires_at=dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1),
        )
        self.assertTrue(session_active(device))
        self.assertFalse(is_operator_deletable_client(device, online=False))


if __name__ == "__main__":
    unittest.main()
