#!/usr/bin/env python3
"""Tests for forward-node nft renderer."""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from node_agent.nft_render import LOCAL_EGRESS_MARK, TPROXY_MARK, render_forward_nft  # noqa: E402


class ForwardNftRenderTests(unittest.TestCase):
    def test_required_chains_and_marks(self) -> None:
        text = render_forward_nft(
            wan_iface="ens160",
            tproxy_iface="ens192",
            tproxy_port=12345,
            bypass_cidrs=["10.0.0.1", "192.168.1.0/24"],
        )
        self.assertIn("table inet gfc", text)
        self.assertIn("set bypass_ip", text)
        self.assertIn("chain prerouting", text)
        self.assertIn("chain output", text)
        self.assertIn(f"meta mark {TPROXY_MARK}", text)
        self.assertIn(f"meta mark set {LOCAL_EGRESS_MARK}", text)
        self.assertIn('iifname "ens160" return', text)
        self.assertIn("tproxy ip to :12345", text)

    def test_bypass_before_tproxy(self) -> None:
        text = render_forward_nft(
            wan_iface="eth0",
            tproxy_iface="eth1",
            tproxy_port=12345,
            bypass_cidrs=["1.2.3.4"],
        )
        bypass_pos = text.index("ip daddr @bypass_ip return")
        tproxy_pos = text.index("tproxy ip to")
        self.assertLess(bypass_pos, tproxy_pos)


if __name__ == "__main__":
    unittest.main()
