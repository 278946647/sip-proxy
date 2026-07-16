"""Tests for node public_ip normalization on control plane."""
from __future__ import annotations

import unittest

from app.node_public_ip import normalize_node_public_ip


class NormalizeNodePublicIpTest(unittest.TestCase):
    def test_accepts_public(self) -> None:
        self.assertEqual(normalize_node_public_ip(" 8.8.4.4 "), "8.8.4.4")

    def test_rejects_private(self) -> None:
        for bad in ("10.0.0.1", "172.16.0.1", "192.168.0.1", "100.64.0.1", "127.0.0.1"):
            self.assertIsNone(normalize_node_public_ip(bad))

    def test_rejects_garbage(self) -> None:
        self.assertIsNone(normalize_node_public_ip(""))
        self.assertIsNone(normalize_node_public_ip(None))
        self.assertIsNone(normalize_node_public_ip("not-an-ip"))


if __name__ == "__main__":
    unittest.main()
