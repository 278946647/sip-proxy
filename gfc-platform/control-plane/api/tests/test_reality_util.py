"""Tests for REALITY default and migration helpers."""
from __future__ import annotations

import unittest

from app.reality_util import (
    REALITY_DEFAULT_DEST,
    REALITY_DEFAULT_PORT,
    REALITY_DEFAULT_SNI,
    default_reality_config,
    ensure_node_reality_config,
    normalize_reality_config,
)


class RealityUtilTest(unittest.TestCase):
    def test_default_reality_uses_cloudflare_8443(self) -> None:
        cfg = default_reality_config()
        self.assertEqual(cfg["listenPort"], REALITY_DEFAULT_PORT)
        self.assertEqual(cfg["serverNames"], [REALITY_DEFAULT_SNI])
        self.assertEqual(cfg["dest"], REALITY_DEFAULT_DEST)

    def test_normalize_legacy_microsoft_config(self) -> None:
        legacy = {
            "enabled": True,
            "listenPort": 443,
            "privateKey": "priv",
            "publicKey": "pub",
            "shortIds": ["abcd"],
            "serverNames": ["www.microsoft.com"],
            "dest": "www.microsoft.com:443",
        }
        out = normalize_reality_config(legacy)
        self.assertEqual(out["listenPort"], 8443)
        self.assertEqual(out["serverNames"], ["www.cloudflare.com"])
        self.assertEqual(out["dest"], "www.cloudflare.com:443")
        self.assertEqual(out["privateKey"], "priv")

    def test_ensure_node_reality_config_migrates_json(self) -> None:
        legacy_json = (
            '{"enabled":true,"listenPort":443,"privateKey":"p","publicKey":"k",'
            '"shortIds":["1"],"serverNames":["www.microsoft.com"],"dest":"www.microsoft.com:443"}'
        )
        out = ensure_node_reality_config(legacy_json)
        self.assertEqual(out["listenPort"], 8443)
        self.assertEqual(out["serverNames"][0], "www.cloudflare.com")


if __name__ == "__main__":
    unittest.main()
