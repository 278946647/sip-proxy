from __future__ import annotations

import json
import unittest

from node_agent.singbox import render_singbox_config


class ClientIngressSingboxTest(unittest.TestCase):
    def test_reality_inbound_and_per_user_outbound(self) -> None:
        dataplane = {
            "tproxyPort": 12345,
            "defaultAction": "drop",
            "rules": [],
            "dnsFallbackEnabled": True,
            "dnsIntlServer": "1.1.1.1",
        }
        client_ingress = {
            "enabled": True,
            "reality": {
                "listenPort": 8443,
                "privateKey": "test-private-key",
                "publicKey": "test-public-key",
                "shortIds": ["a1b2c3d4"],
                "serverNames": ["www.cloudflare.com"],
                "dest": "www.cloudflare.com:443",
            },
            "users": [
                {
                    "lineId": 1,
                    "tid": "TID-001",
                    "uuid": "11111111-1111-1111-1111-111111111111",
                    "flow": "xtls-rprx-vision",
                    "outbound": {
                        "mode": "socks",
                        "host": "1.2.3.4",
                        "port": 1080,
                        "username": "u",
                        "password": "p",
                    },
                },
                {
                    "lineId": 2,
                    "tid": "TID-002",
                    "uuid": "22222222-2222-2222-2222-222222222222",
                    "flow": "xtls-rprx-vision",
                    "outbound": {"mode": "direct"},
                },
            ],
        }

        cfg = render_singbox_config(
            dataplane,
            client_ingress=client_ingress,
            socks_dns_ok={"client-1": True},
        )

        inbounds = {ib["tag"]: ib for ib in cfg["inbounds"]}
        self.assertIn("vless-reality-in", inbounds)
        vless = inbounds["vless-reality-in"]
        self.assertEqual(vless["listen_port"], 8443)
        self.assertEqual(vless["listen"], "0.0.0.0")
        self.assertEqual(vless["tls"]["server_name"], "www.cloudflare.com")
        self.assertEqual(len(vless["users"]), 2)
        self.assertTrue(vless["tls"]["reality"]["enabled"])

        tags = {ob["tag"] for ob in cfg["outbounds"]}
        self.assertIn("client-1", tags)
        self.assertIn("direct", tags)

        user_routes = [
            r
            for r in cfg["route"]["rules"]
            if r.get("inbound") == "vless-reality-in" and r.get("action") == "route"
        ]
        self.assertEqual(len(user_routes), 2)
        by_user = {r["auth_user"][0]: r["outbound"] for r in user_routes}
        self.assertEqual(by_user["client-1"], "client-1")
        self.assertEqual(by_user["client-2"], "direct")
        self.assertEqual(cfg["route"]["final"], "direct")
        self.assertFalse(cfg["route"]["auto_detect_interface"])
        for r in user_routes:
            self.assertIn("auth_user", r)
            self.assertNotIn("user", r)
        self.assertNotIn("tproxy-in", inbounds)

        # sanity: json serializable
        json.dumps(cfg)


if __name__ == "__main__":
    unittest.main()
