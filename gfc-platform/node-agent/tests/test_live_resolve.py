"""Tests for per-line live resolve worker."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from node_agent import live_resolve


class LiveResolveWorkerTests(unittest.TestCase):
    def test_skips_when_socks_unhealthy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            live_resolve.RESOLVE_DIR = Path(tmp)
            payload = {
                "liveCatalog": {
                    "catalogEpoch": "epoch-1",
                    "dohUrl": "https://1.1.1.1/dns-query",
                    "tasks": [
                        {
                            "lineId": 7,
                            "liveMode": "live_catalog",
                            "detourTag": "client-7",
                            "egressHint": "socks:1080",
                            "catalogEpoch": "e7",
                            "domains": ["a.rtmp.youtube.com"],
                            "staticCidrs": [],
                            "outbound": {
                                "mode": "socks",
                                "host": "1.2.3.4",
                                "port": 1080,
                            },
                        }
                    ],
                }
            }
            results = live_resolve.maybe_run_live_resolve(
                payload, {"client-7": False}
            )
            self.assertEqual(len(results), 1)
            self.assertTrue(results[0]["skippedUnhealthy"])
            cache = json.loads((Path(tmp) / "line-7.json").read_text(encoding="utf-8"))
            self.assertTrue(cache["skippedUnhealthy"])

    def test_doh_json_parses_answer(self) -> None:
        fake = mock.Mock(returncode=0, stdout=json.dumps({
            "Answer": [{"type": 1, "data": "142.250.80.46"}],
        }))
        with mock.patch("node_agent.live_resolve.subprocess.run", return_value=fake):
            ips = live_resolve._doh_json_a_records(
                "a.rtmp.youtube.com",
                proxy="socks5h://1.2.3.4:1080",
                doh_url="https://1.1.1.1/dns-query",
            )
        self.assertEqual(ips, ["142.250.80.46"])


if __name__ == "__main__":
    unittest.main()
