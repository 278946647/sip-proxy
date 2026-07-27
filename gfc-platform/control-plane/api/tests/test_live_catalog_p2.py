"""P2 live catalog admin workflow tests."""
from __future__ import annotations

import unittest

from app.live_catalog import ENDPOINT_SEEDS, PLATFORM_SPECS, validate_resolve_report


class LiveCatalogP2Tests(unittest.TestCase):
    def test_platform_seed_coverage(self) -> None:
        ids = {p[0] for p in PLATFORM_SPECS}
        self.assertIn("youtube_live", ids)
        self.assertIn("twitch", ids)
        self.assertIn("lazada_live", ids)
        self.assertIn("facebook_live", ids)
        self.assertGreaterEqual(len(ids), 12)

    def test_youtube_and_twitch_active_seeds(self) -> None:
        active = {
            (p, v)
            for p, _r, _m, v, _c, _s, st, _rg in ENDPOINT_SEEDS
            if st == "active"
        }
        self.assertIn(("youtube_live", "a.rtmp.youtube.com"), active)
        self.assertIn(("twitch", "live.twitch.tv"), active)

    def test_v6_skipped_unhealthy(self) -> None:
        task = {"lineId": 1, "detourTag": "client-1", "egressHint": "h:1080"}
        ok, alert_type, _ = validate_resolve_report(
            1,
            task,
            {
                "lineId": 1,
                "detourTag": "client-1",
                "skippedUnhealthy": True,
            },
        )
        self.assertFalse(ok)
        self.assertEqual(alert_type, "resolve_vantage_mismatch")


if __name__ == "__main__":
    unittest.main()
