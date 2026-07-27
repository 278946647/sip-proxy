"""Tests for client config bundle builder."""
from __future__ import annotations

import unittest
from types import SimpleNamespace

from app.client_config import build_client_payload, client_payload_version


class ClientConfigRoutingTests(unittest.TestCase):
    def test_build_client_payload_includes_routing_scheme(self) -> None:
        device = SimpleNamespace(
            id=1,
            name="box-1",
            proxy_mode="gateway",
            routing_scheme="global",
        )
        line = SimpleNamespace(
            id=10,
            tid="T001",
            client_uuid="uuid-1",
            bandwidth_mbps=100,
            is_enabled=True,
            live_mode="standard",
            hy2_password="test-hy2-pass",
            hy2_brutal_enabled=True,
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
            hysteria2_config_json=(
                '{"enabled":true,"listenPort":18443,"serverName":"www.cloudflare.com",'
                '"masquerade":"https://www.cloudflare.com/",'
                '"certificate":"-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----",'
                '"key":"-----BEGIN PRIVATE KEY-----\\nMIIE\\n-----END PRIVATE KEY-----",'
                '"salamanderEnabled":false}'
            ),
        )
        payload = build_client_payload(device, line, node, None)
        self.assertEqual(payload["routingScheme"], "global")
        self.assertEqual(payload["liveMode"], "standard")
        self.assertEqual(payload["hysteria2"]["upMbps"], 93)
        self.assertEqual(payload["node"]["hy2Port"], 18443)
        self.assertIn("controlPlaneServers", payload)
        self.assertTrue(payload["controlPlaneServers"])

    def test_routing_scheme_change_bumps_version(self) -> None:
        base_device = SimpleNamespace(
            id=1,
            name="box-1",
            proxy_mode="gateway",
            routing_scheme="split",
        )
        global_device = SimpleNamespace(
            id=1,
            name="box-1",
            proxy_mode="gateway",
            routing_scheme="global",
        )
        line = SimpleNamespace(
            id=10,
            tid="T001",
            client_uuid="uuid-1",
            bandwidth_mbps=100,
            is_enabled=True,
            live_mode="standard",
            hy2_password="test-hy2-pass",
            hy2_brutal_enabled=True,
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
            hysteria2_config_json=(
                '{"enabled":true,"listenPort":18443,"serverName":"www.cloudflare.com",'
                '"masquerade":"https://www.cloudflare.com/",'
                '"certificate":"CERT","key":"KEY","salamanderEnabled":false}'
            ),
        )
        v1 = client_payload_version(build_client_payload(base_device, line, node, None))
        v2 = client_payload_version(build_client_payload(global_device, line, node, None))
        self.assertNotEqual(v1, v2)

    def test_live_mode_change_bumps_version(self) -> None:
        device = SimpleNamespace(
            id=1,
            name="box-1",
            proxy_mode="gateway",
            routing_scheme="split",
        )
        line_std = SimpleNamespace(
            id=10,
            tid="T001",
            client_uuid="uuid-1",
            bandwidth_mbps=100,
            is_enabled=True,
            live_mode="standard",
            hy2_password="test-hy2-pass",
            hy2_brutal_enabled=True,
        )
        line_hy2 = SimpleNamespace(
            id=10,
            tid="T001",
            client_uuid="uuid-1",
            bandwidth_mbps=100,
            is_enabled=True,
            live_mode="live_all_hy2",
            hy2_password="test-hy2-pass",
            hy2_brutal_enabled=True,
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
            hysteria2_config_json=(
                '{"enabled":true,"listenPort":18443,"serverName":"www.cloudflare.com",'
                '"masquerade":"https://www.cloudflare.com/",'
                '"certificate":"CERT","key":"KEY","salamanderEnabled":false}'
            ),
        )
        v1 = client_payload_version(build_client_payload(device, line_std, node, None))
        v2 = client_payload_version(build_client_payload(device, line_hy2, node, None))
        self.assertNotEqual(v1, v2)

    def test_live_catalog_payload_includes_platforms(self) -> None:
        device = SimpleNamespace(
            id=1,
            name="box-1",
            proxy_mode="gateway",
            routing_scheme="split",
            line_id=10,
        )
        line = SimpleNamespace(
            id=10,
            tid="T001",
            client_uuid="uuid-1",
            bandwidth_mbps=100,
            is_enabled=True,
            live_mode="live_catalog",
            live_platforms_json='["youtube_live"]',
            hy2_password="test-hy2-pass",
            hy2_brutal_enabled=True,
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
            hysteria2_config_json=(
                '{"enabled":true,"listenPort":18443,"serverName":"www.cloudflare.com",'
                '"masquerade":"https://www.cloudflare.com/",'
                '"certificate":"CERT","key":"KEY","salamanderEnabled":false}'
            ),
        )
        payload = build_client_payload(device, line, node, None)
        self.assertEqual(payload["liveMode"], "live_catalog")
        self.assertEqual(payload["livePlatforms"], ["youtube_live"])


if __name__ == "__main__":
    unittest.main()
