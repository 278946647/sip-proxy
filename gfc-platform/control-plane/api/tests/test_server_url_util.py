import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.server_url_util import (  # noqa: E402
    normalize_server_url,
    parse_server_url_list,
    public_server_urls_from_settings,
    urls_from_activation_payload,
)


class ServerUrlUtilTests(unittest.TestCase):
    def test_line_code_payload_urls(self) -> None:
        urls = urls_from_activation_payload(
            {
                "server": "http://api.example.com:8181",
                "serverFallback": "http://192.168.1.10:8181",
            }
        )
        self.assertEqual(len(urls), 2)

    def test_public_urls_from_ip_fallback(self) -> None:
        urls = public_server_urls_from_settings(
            "http://api.example.com:8181",
            fallback_ip="192.168.1.10",
        )
        self.assertEqual(urls[1], "http://192.168.1.10:8181")

    def test_csv_list(self) -> None:
        urls = parse_server_url_list("api.example.com, 10.0.0.1")
        self.assertEqual(
            urls,
            ["http://api.example.com:8181", "http://10.0.0.1:8181"],
        )


if __name__ == "__main__":
    unittest.main()
