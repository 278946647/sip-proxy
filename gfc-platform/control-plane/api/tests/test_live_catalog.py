"""Tests for live_catalog validation helpers."""
from __future__ import annotations

import unittest

from app.live_catalog import validate_resolve_report


class LiveCatalogValidationTests(unittest.TestCase):
    def test_v1_detour_mismatch(self) -> None:
        task = {"lineId": 1, "detourTag": "client-1", "egressHint": "1.2.3.4:1080"}
        report = {
            "lineId": 1,
            "detourTag": "client-2",
            "egressHint": "1.2.3.4:1080",
            "cidrs": ["9.9.9.9/32"],
        }
        ok, alert_type, _ = validate_resolve_report(1, task, report)
        self.assertFalse(ok)
        self.assertEqual(alert_type, "resolve_vantage_mismatch")

    def test_v2_line_id_mismatch(self) -> None:
        task = {"lineId": 1, "detourTag": "client-1", "egressHint": "1.2.3.4:1080"}
        report = {
            "lineId": 2,
            "detourTag": "client-1",
            "egressHint": "1.2.3.4:1080",
            "cidrs": ["9.9.9.9/32"],
        }
        ok, alert_type, _ = validate_resolve_report(1, task, report)
        self.assertFalse(ok)
        self.assertEqual(alert_type, "live_ip_line_mismatch")

    def test_ok_report(self) -> None:
        task = {"lineId": 1, "detourTag": "client-1", "egressHint": "1.2.3.4:1080"}
        report = {
            "lineId": 1,
            "detourTag": "client-1",
            "egressHint": "1.2.3.4:1080",
            "cidrs": ["9.9.9.9/32"],
        }
        ok, alert_type, _ = validate_resolve_report(1, task, report)
        self.assertTrue(ok)
        self.assertIsNone(alert_type)


if __name__ == "__main__":
    unittest.main()
