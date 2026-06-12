import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from node_agent.server_url import normalize_server_url, parse_server_url_list, resolve_server_urls_from_env


class ServerUrlTests(unittest.TestCase):
    def test_domain(self) -> None:
        self.assertEqual(
            normalize_server_url("api.example.com"),
            "http://api.example.com:8080",
        )

    def test_ipv4(self) -> None:
        self.assertEqual(
            normalize_server_url("192.168.1.10"),
            "http://192.168.1.10:8080",
        )

    def test_full_url(self) -> None:
        self.assertEqual(
            normalize_server_url("https://api.example.com:8443"),
            "https://api.example.com:8443",
        )

    def test_primary_and_fallback(self) -> None:
        urls = parse_server_url_list(
            "http://api.example.com:8080",
            "192.168.1.10",
        )
        self.assertEqual(
            urls,
            ["http://api.example.com:8080", "http://192.168.1.10:8080"],
        )

    def test_env_resolution(self) -> None:
        os.environ["SERVER_URL"] = "api.example.com"
        os.environ["SERVER_URL_FALLBACK"] = "10.0.0.5"
        try:
            urls = resolve_server_urls_from_env()
        finally:
            os.environ.pop("SERVER_URL", None)
            os.environ.pop("SERVER_URL_FALLBACK", None)
        self.assertEqual(urls[0], "http://api.example.com:8080")
        self.assertEqual(urls[1], "http://10.0.0.5:8080")


if __name__ == "__main__":
    unittest.main()
