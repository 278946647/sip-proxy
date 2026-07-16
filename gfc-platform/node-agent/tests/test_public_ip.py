"""Tests for forward-node public IP detection."""
from __future__ import annotations

import unittest
from unittest import mock

from node_agent.public_ip import detect_public_ip, is_globally_routable_ipv4


class PublicIpHelpersTest(unittest.TestCase):
    def test_rejects_private_and_cgnat(self) -> None:
        for bad in (
            "10.0.0.1",
            "172.16.5.9",
            "192.168.1.1",
            "100.64.1.2",
            "127.0.0.1",
            "169.254.1.1",
            "not-an-ip",
            "",
            None,
        ):
            self.assertFalse(is_globally_routable_ipv4(bad))  # type: ignore[arg-type]

    def test_accepts_public(self) -> None:
        self.assertTrue(is_globally_routable_ipv4("8.8.8.8"))
        self.assertTrue(is_globally_routable_ipv4("203.0.113.10"))


class DetectPublicIpTest(unittest.TestCase):
    def test_env_override_wins(self) -> None:
        with mock.patch.dict(
            "os.environ",
            {"GFC_NODE_PUBLIC_IP": "203.0.113.50", "GFC_PUBLIC_IP": "198.51.100.1"},
            clear=False,
        ):
            with mock.patch("node_agent.public_ip._probe_http") as http:
                self.assertEqual(detect_public_ip(), "203.0.113.50")
                http.assert_not_called()

    def test_env_private_ignored_falls_through(self) -> None:
        with mock.patch.dict("os.environ", {"GFC_NODE_PUBLIC_IP": "10.1.2.3"}, clear=False):
            with mock.patch(
                "node_agent.public_ip._probe_gcp_metadata", return_value=None
            ), mock.patch(
                "node_agent.public_ip._probe_http", return_value="198.51.100.9"
            ), mock.patch(
                "node_agent.public_ip._probe_udp_source", return_value="10.0.0.5"
            ):
                self.assertEqual(detect_public_ip(), "198.51.100.9")

    def test_rejects_udp_private_when_http_fails(self) -> None:
        env = {
            k: v
            for k, v in __import__("os").environ.items()
            if k not in ("GFC_NODE_PUBLIC_IP", "GFC_PUBLIC_IP")
        }
        with mock.patch.dict("os.environ", env, clear=True):
            with mock.patch(
                "node_agent.public_ip._probe_gcp_metadata", return_value=None
            ), mock.patch(
                "node_agent.public_ip._probe_http", return_value=None
            ), mock.patch(
                "node_agent.public_ip._probe_udp_source", return_value="10.128.0.2"
            ):
                self.assertIsNone(detect_public_ip())


if __name__ == "__main__":
    unittest.main()
