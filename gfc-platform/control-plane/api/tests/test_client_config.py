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
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
        )
        payload = build_client_payload(device, line, node, None)
        self.assertEqual(payload["routingScheme"], "global")
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
        )
        node = SimpleNamespace(
            id=2,
            name="node-1",
            public_ip="103.78.41.15",
            reality_config_json='{"publicKey":"pk","shortIds":[""],"serverNames":["www.cloudflare.com"]}',
        )
        v1 = client_payload_version(build_client_payload(base_device, line, node, None))
        v2 = client_payload_version(build_client_payload(global_device, line, node, None))
        self.assertNotEqual(v1, v2)


if __name__ == "__main__":
    unittest.main()
