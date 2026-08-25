#!/usr/bin/env python3
"""Tests for client nft policy generator (architecture mode)."""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

DEPLOY = os.path.join(os.path.dirname(__file__), "..")
spec = importlib.util.spec_from_file_location(
    "gen_nft_policy",
    os.path.join(DEPLOY, "gen-nft-policy.py"),
)
gnp = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(gnp)


class ClientNftArchitectureTests(unittest.TestCase):
    def test_kernel_split_uses_inet_gfc_chains(self) -> None:
        cfg = {
            "lan": "br-lan",
            "lan_cidr": "192.168.1.0/24",
            "mark": "0x2023",
            "tun": "gfctun",
            "wan": "eth0",
            "mosdns_uid": "65353",
            "singbox_uid": "65354",
            "ssh_port": "212",
            "redirect_port": "11800",
            "ext_const_ips": ["1.1.1.1", "8.8.8.8"],
            "bypass_ips": ["103.78.41.16"],
            "cn_count": 0,
            "cn_load_path": "/tmp/cn.nft",
            "routing_mode": "split",
        }
        text = gnp.render_architecture(cfg)
        for needle in (
            "table inet gfc",
            "set TO_CN",
            "set TO_RFC1918",
            "set bypass_ip",
            "set ext_const",
            "chain prerouting_mangle_ct",
            "chain prerouting_mangle_route",
            "chain gfc_forward",
            "chain output_mangle_route",
            "0x00002023",
        ):
            self.assertIn(needle, text, msg=needle)
        self.assertNotIn("skuid", text)
        self.assertNotIn("gfc_client_mangle", text)
        self.assertNotIn("cn_ip", text)
        self.assertNotIn("ip daddr @TO_RFC1918 return\n    ip daddr 127.0.0.0/8 return\n    ip daddr @customer_hosts return", text)

    def test_global_mode_omits_to_cn_return(self) -> None:
        cfg = {
            "lan": "br-lan",
            "lan_cidr": "192.168.1.0/24",
            "mark": "0x2023",
            "tun": "gfctun",
            "wan": "eth0",
            "mosdns_uid": "65353",
            "singbox_uid": "65354",
            "ssh_port": "212",
            "redirect_port": "11800",
            "ext_const_ips": ["1.1.1.1", "8.8.8.8"],
            "bypass_ips": ["103.78.41.16"],
            "cn_count": 1,
            "cn_load_path": "/tmp/cn.nft",
            "routing_mode": "global",
        }
        text = gnp.render_architecture(cfg)
        self.assertIn("routing_mode=global", text)
        self.assertNotIn("ip daddr @TO_CN return", text)
        self.assertIn("set TO_CN", text)

    def test_split_mode_keeps_to_cn_return(self) -> None:
        cfg = {
            "lan": "br-lan",
            "lan_cidr": "192.168.1.0/24",
            "mark": "0x2023",
            "tun": "gfctun",
            "wan": "eth0",
            "mosdns_uid": "65353",
            "singbox_uid": "65354",
            "ssh_port": "212",
            "redirect_port": "11800",
            "ext_const_ips": ["1.1.1.1", "8.8.8.8"],
            "bypass_ips": [],
            "cn_count": 1,
            "cn_load_path": "/tmp/cn.nft",
            "routing_mode": "split",
        }
        text = gnp.render_architecture(cfg)
        self.assertIn("ip daddr @TO_CN return", text)

    def test_bypass_option_b(self) -> None:
        cfg = {
            "lan": "br-lan",
            "lan_cidr": "192.168.68.0/24",
            "mark": "0x2023",
            "tun": "gfctun",
            "wan": "eth0",
            "mosdns_uid": "65353",
            "singbox_uid": "65354",
            "ssh_port": "212",
            "redirect_port": "11800",
            "ext_const_ips": ["1.1.1.1", "8.8.8.8"],
            "bypass_ips": ["103.78.41.16"],
            "cn_count": 1,
            "cn_load_path": "/tmp/cn.nft",
            "routing_mode": "split",
            "proxy_mode": "bypass",
            "customer_hosts": ["10.20.30.0/24"],
        }
        text = gnp.render_architecture(cfg)
        for needle in (
            'iifname "eth0" ip saddr @customer_hosts ct mark set 0x00002023 accept',
            'iifname "eth0" ip saddr @customer_hosts ip daddr @TO_CN return',
            "ct state new ip saddr @customer_hosts ct mark set meta mark",
            "set customer_hosts",
            'iifname "gfctun" return',
            "fib daddr type { local, broadcast, multicast } return",
            "ip daddr @TO_RFC1918 return\n    ip daddr 127.0.0.0/8 return\n    ip daddr @customer_hosts return",
        ):
            self.assertIn(needle, text, msg=needle)
        self.assertNotIn("skuid", text)

    def test_cn_load_targets_to_cn(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            etc = Path(tmp)
            with mock.patch.object(gnp, "etc_dir", return_value=etc):
                with mock.patch.object(gnp, "load_cn_cidrs", return_value=["1.0.1.0/24", "223.5.5.5/32"]):
                    path = gnp.write_cn_load_nft(["1.0.1.0/24", "223.5.5.5/32"])
            body = path.read_text()
            self.assertIn("add element inet gfc TO_CN", body)


if __name__ == "__main__":
    unittest.main()
