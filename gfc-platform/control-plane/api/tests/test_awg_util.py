"""Tests for AmneziaWG control-plane helpers."""
from __future__ import annotations

import json
import unittest

from app.awg_util import (
    AWG_DEFAULT_MTU,
    AWG_RESERVED_ADDRS_PER_NODE,
    AwgPoolExhausted,
    allocate_inner_ip,
    awg_checksum,
    default_node_awg_config,
    default_obfuscation_params,
    derive_public_key,
    ensure_node_awg_config,
    generate_keypair,
    generate_obfuscation_params,
    generate_preshared_key,
    is_valid_key,
    normalize_pool_cidr,
    validate_inner_ip,
    validate_key,
    validate_mtu,
    validate_obfuscation_params,
)


class AwgKeyTest(unittest.TestCase):
    def test_generate_keypair_is_valid_and_stable_derivation(self) -> None:
        try:
            import cryptography  # noqa: F401
        except ImportError:  # pragma: no cover - 部署环境已安装
            self.skipTest("cryptography not installed")

        private_key, public_key = generate_keypair()
        self.assertTrue(is_valid_key(private_key))
        self.assertTrue(is_valid_key(public_key))
        self.assertNotEqual(private_key, public_key)
        self.assertEqual(derive_public_key(private_key), public_key)

        other_private, _ = generate_keypair()
        self.assertNotEqual(private_key, other_private)

    def test_validate_key_rejects_non_32_byte_values(self) -> None:
        for bad in (None, 123, "", "not-base64", "AAAA", "A" * 44 + "="):
            with self.subTest(bad=bad):
                self.assertFalse(is_valid_key(bad))
                with self.assertRaises(ValueError):
                    validate_key(bad)

    def test_generate_preshared_key(self) -> None:
        psk = generate_preshared_key()
        self.assertTrue(is_valid_key(psk))
        self.assertNotEqual(psk, generate_preshared_key())


class AwgObfuscationTest(unittest.TestCase):
    def test_default_params_are_valid(self) -> None:
        params = default_obfuscation_params()
        self.assertEqual(validate_obfuscation_params(params), [])
        self.assertEqual(
            params,
            {
                "jc": 4,
                "jmin": 40,
                "jmax": 70,
                "s1": 30,
                "s2": 40,
                "h1": 1,
                "h2": 2,
                "h3": 3,
                "h4": 4,
            },
        )

    def test_generated_params_are_valid_and_distinct_h(self) -> None:
        params = generate_obfuscation_params()
        self.assertEqual(validate_obfuscation_params(params), [])
        self.assertEqual(len({params[f"h{i}"] for i in range(1, 5)}), 4)
        self.assertLessEqual(params["jmin"], params["jmax"])

    def test_validate_rejects_missing_unknown_and_partial(self) -> None:
        params = default_obfuscation_params()
        partial = dict(params)
        partial.pop("s2")
        self.assertTrue(any("缺少参数" in item for item in validate_obfuscation_params(partial)))

        unknown = dict(params)
        unknown["s1_extra"] = 1
        self.assertTrue(any("未知参数" in item for item in validate_obfuscation_params(unknown)))

        self.assertEqual(validate_obfuscation_params(None)[0], "obfuscation 必须是对象")

    def test_validate_rejects_out_of_range_and_bad_types(self) -> None:
        params = default_obfuscation_params()
        params["jc"] = 0
        self.assertTrue(any("jc" in item for item in validate_obfuscation_params(params)))

        params = default_obfuscation_params()
        params["jmin"] = 200
        params["jmax"] = 100
        self.assertIn("jmin 不得大于 jmax", validate_obfuscation_params(params))

        params = default_obfuscation_params()
        params["h2"] = params["h1"]
        self.assertIn("h1..h4 必须互不相同", validate_obfuscation_params(params))

        params = default_obfuscation_params()
        params["s1"] = True
        self.assertTrue(any("s1 必须是整数" in item for item in validate_obfuscation_params(params)))


class AwgChecksumTest(unittest.TestCase):
    def test_checksum_is_order_independent_and_sensitive(self) -> None:
        params = default_obfuscation_params()
        reordered = dict(reversed(list(params.items())))

        base = awg_checksum(params_version=3, obfuscation=params, server_public_key="pub-a")
        self.assertEqual(
            base,
            awg_checksum(params_version=3, obfuscation=reordered, server_public_key="pub-a"),
        )
        self.assertEqual(len(base), 64)

        changed_param = dict(params)
        changed_param["s1"] += 1
        self.assertNotEqual(
            base,
            awg_checksum(params_version=3, obfuscation=changed_param, server_public_key="pub-a"),
        )
        self.assertNotEqual(
            base,
            awg_checksum(params_version=4, obfuscation=params, server_public_key="pub-a"),
        )
        self.assertNotEqual(
            base,
            awg_checksum(params_version=3, obfuscation=params, server_public_key="pub-b"),
        )

    def test_checksum_rejects_invalid_params(self) -> None:
        params = default_obfuscation_params()
        params.pop("h4")
        with self.assertRaises(ValueError):
            awg_checksum(params_version=1, obfuscation=params)


class AwgInnerIpTest(unittest.TestCase):
    def test_validate_inner_ip_normalizes(self) -> None:
        self.assertEqual(validate_inner_ip("10.66.12.7"), "10.66.12.7/32")
        self.assertEqual(validate_inner_ip("10.66.12.7/32"), "10.66.12.7/32")
        for bad in ("10.66.12.0/24", "not-an-ip", "::1", "224.0.0.1", "127.0.0.1"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    validate_inner_ip(bad)

    def test_allocate_skips_reserved_and_used(self) -> None:
        first = allocate_inner_ip("10.66.0.0/24")
        self.assertEqual(first, "10.66.0.17/32")

        second = allocate_inner_ip("10.66.0.0/24", used=[first])
        self.assertEqual(second, "10.66.0.18/32")

        third = allocate_inner_ip(
            "10.66.0.0/24",
            used=["10.66.0.17/32", "10.66.0.18"],
            server_inner_ip="10.66.0.19",
        )
        self.assertEqual(third, "10.66.0.20/32")

        self.assertEqual(AWG_RESERVED_ADDRS_PER_NODE, 16)

    def test_allocate_exhausted_and_bad_pool(self) -> None:
        with self.assertRaises(AwgPoolExhausted):
            allocate_inner_ip("10.66.0.0/30")

        with self.assertRaises(ValueError):
            normalize_pool_cidr("10.66.0.1/24")  # 非网络地址
        with self.assertRaises(ValueError):
            normalize_pool_cidr("10.66.0.0/32")
        with self.assertRaises(ValueError):
            normalize_pool_cidr("fd00::/64")


class AwgNodeConfigTest(unittest.TestCase):
    def test_default_node_config_is_complete_and_stable(self) -> None:
        try:
            import cryptography  # noqa: F401
        except ImportError:  # pragma: no cover
            self.skipTest("cryptography not installed")

        cfg = default_node_awg_config("10.66.0.0/16")
        self.assertEqual(cfg["iface"], "awg0")
        self.assertEqual(cfg["listenPort"], 51820)
        self.assertEqual(cfg["serverInnerIp"], "10.66.0.1/24")
        self.assertTrue(is_valid_key(cfg["serverPrivateKey"]))
        self.assertTrue(is_valid_key(cfg["serverPublicKey"]))
        self.assertEqual(validate_obfuscation_params(cfg["obfuscation"]), [])
        self.assertEqual(len(cfg["checksum"]), 64)

        again = ensure_node_awg_config(json.dumps(cfg), "10.66.0.0/16")
        self.assertEqual(again["serverPublicKey"], cfg["serverPublicKey"])
        self.assertEqual(again["checksum"], cfg["checksum"])

    def test_ensure_repairs_invalid_params(self) -> None:
        try:
            import cryptography  # noqa: F401
        except ImportError:  # pragma: no cover
            self.skipTest("cryptography not installed")

        cfg = ensure_node_awg_config(
            '{"enabled": true, "obfuscation": {"jc": 0}, "mtu": 9999}',
            "10.66.0.0/16",
        )
        self.assertEqual(validate_obfuscation_params(cfg["obfuscation"]), [])
        self.assertEqual(cfg["mtu"], AWG_DEFAULT_MTU)


class AwgMtuTest(unittest.TestCase):
    def test_mtu_bounds(self) -> None:
        self.assertEqual(validate_mtu(), AWG_DEFAULT_MTU)
        self.assertEqual(validate_mtu(1280), 1280)
        self.assertEqual(validate_mtu(1420), 1420)
        for bad in (1279, 1421, True, "1408"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    validate_mtu(bad)


if __name__ == "__main__":
    unittest.main()
