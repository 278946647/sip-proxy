from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from client_agent.rules_fetch import RULE_SPECS, RULES_DIR, ensure_local_rules, local_rules_available
from client_agent.singbox import DOMESTIC_DNS_CIDRS, render_singbox_config, render_singbox_idle_config


def _sample_payload() -> dict:
    return {
        "node": {"address": "203.0.113.10", "port": 443},
        "vless": {
            "uuid": "00000000-0000-4000-8000-000000000001",
            "publicKey": "test",
            "shortId": "abcd",
        },
        "proxyMode": "gateway",
        "routingMode": "split",
    }


class SingboxConfigTests(unittest.TestCase):
    def test_idle_has_no_hijack(self) -> None:
        cfg = render_singbox_idle_config()
        self.assertEqual(cfg["inbounds"], [])
        self.assertEqual(cfg["route"]["final"], "direct")
        self.assertEqual(cfg["log"]["level"], "error")

    def test_active_hijacks_dns_to_mosdns(self) -> None:
        with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "0", "GFC_WAN_IFACE": "ens160"}, clear=False):
            cfg = render_singbox_config(_sample_payload())
        dns_rules = [r for r in cfg["route"]["rules"] if r.get("action") == "hijack-dns"]
        self.assertEqual(len(dns_rules), 1)
        self.assertEqual(dns_rules[0].get("port"), [53])
        self.assertEqual(cfg["dns"]["final"], "mosdns")
        tags = {s["tag"] for s in cfg["dns"]["servers"]}
        self.assertIn("local", tags)
        self.assertIn("mosdns", tags)
        mosdns_srv = next(s for s in cfg["dns"]["servers"] if s["tag"] == "mosdns")
        self.assertNotIn("detour", mosdns_srv)
        ob_tags = {o["tag"] for o in cfg["outbounds"]}
        self.assertIn("direct-local", ob_tags)

    def test_mosdns_bypass_before_hijack(self) -> None:
        with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "0", "GFC_WAN_IFACE": "ens160"}, clear=False):
            cfg = render_singbox_config(_sample_payload())
        rules = cfg["route"]["rules"]
        mosdns_idx = next(
            i
            for i, r in enumerate(rules)
            if r.get("ip_cidr") == ["127.0.0.1/32"]
            and r.get("port") == [5335]
            and r.get("outbound") == "direct-local"
        )
        hijack_idx = next(i for i, r in enumerate(rules) if r.get("action") == "hijack-dns")
        self.assertLess(mosdns_idx, hijack_idx)

    def test_domestic_dns_direct_intl_via_proxy(self) -> None:
        with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "0", "GFC_WAN_IFACE": "ens160"}, clear=False):
            cfg = render_singbox_config(_sample_payload())
        rules = cfg["route"]["rules"]
        domestic = next(r for r in rules if "223.5.5.5" in (r.get("ip_cidr") or []))
        self.assertEqual(domestic["outbound"], "direct")
        self.assertEqual(domestic["port"], [53])
        intl = next(r for r in rules if "8.8.8.8" in (r.get("ip_cidr") or []))
        self.assertEqual(intl["outbound"], "proxy")
        direct_ob = next(o for o in cfg["outbounds"] if o.get("tag") == "direct")
        self.assertEqual(direct_ob.get("bind_interface"), "ens160")

    def test_split_uses_meta_rules_when_present(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            rules_dir = Path(tmp)
            for _tag, filename, _remote in RULE_SPECS:
                (rules_dir / filename).write_bytes(b"\x00" * 128)
            with patch("client_agent.rules_fetch.RULES_DIR", rules_dir):
                with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "0"}, clear=False):
                    cfg = render_singbox_config(_sample_payload())
            tags = {rs["tag"] for rs in cfg["route"].get("rule_set", [])}
            self.assertIn("geosite-cn", tags)
            rule_sets = [r.get("rule_set") for r in cfg["route"]["rules"] if "rule_set" in r]
            self.assertIn("geosite-cn", rule_sets)
            self.assertIn("geosite-geolocation-!cn", rule_sets)

    def test_global_skips_split_rules(self) -> None:
        payload = _sample_payload()
        payload["routingMode"] = "global"
        with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "0"}, clear=False):
            cfg = render_singbox_config(payload)
        self.assertFalse(any("rule_set" in r for r in cfg["route"]["rules"]))
        self.assertEqual(cfg["route"]["rules"][-1], {"outbound": "proxy"})

    def test_verbose_log_level(self) -> None:
        with patch.dict(os.environ, {"GFC_VERBOSE_LOG": "1", "GFC_SINGBOX_LOG_LEVEL": "debug"}, clear=False):
            cfg = render_singbox_idle_config()
        self.assertEqual(cfg["log"]["level"], "debug")


class RulesFetchTests(unittest.TestCase):
    def test_copy_bundle_rules(self) -> None:
        bundle = Path(__file__).resolve().parent.parent / "deploy" / "rules"
        if not (bundle / "geosite-cn.srs").is_file():
            self.skipTest("bundled rules not present")
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            with patch("client_agent.rules_fetch.RULES_DIR", target):
                ok, _msg = ensure_local_rules(try_download=False)
            self.assertTrue(ok)
            self.assertTrue(local_rules_available())


if __name__ == "__main__":
    unittest.main()
