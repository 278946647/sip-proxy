import unittest

from starlette.responses import Response

from app.remote_proxy import (
    _build_response,
    _collapse_remote_prefix,
    _inject_luci_remote_base,
    _normalize_cgi_path,
    _normalize_luci_path,
    _parse_remote_device_id,
    _remote_auth_cookie_name,
    _rewrite_html_asset_paths,
    _rewrite_remote_location,
    _rewrite_set_cookie,
    _upstream_cookie,
)


class RemoteProxyRewriteTest(unittest.TestCase):
    def test_rewrite_html_asset_paths(self) -> None:
        text = '<link href="/luci-static/luci.css"><script src="/cgi-bin/luci/admin/ubus"></script>'
        out = _rewrite_html_asset_paths(text, 6)
        self.assertIn('href="/remote/6/luci-static/', out)
        self.assertIn('src="/remote/6/cgi-bin/', out)

    def test_rewrite_html_skips_inline_js_literals(self) -> None:
        text = "fetch('/cgi-bin/luci/admin/ubus')"
        out = _rewrite_html_asset_paths(text, 6)
        self.assertEqual(out, text)

    def test_collapse_remote_prefix(self) -> None:
        path = "/remote/6/remote/6/cgi-bin/luci/admin/ubus"
        self.assertEqual(
            _collapse_remote_prefix(path, 6),
            "/remote/6/cgi-bin/luci/admin/ubus",
        )

    def test_rewrite_set_cookie_path(self) -> None:
        raw = "sysauth=abc; Path=/cgi-bin/luci/; HttpOnly"
        out = _rewrite_set_cookie(raw, 6)
        self.assertIn("Path=/remote/6/", out)

    def test_rewrite_location(self) -> None:
        loc = _rewrite_remote_location("/cgi-bin/luci/admin/", 6)
        self.assertEqual(loc, "/remote/6/cgi-bin/luci/admin/")

    def test_rewrite_location_collapses_double_prefix(self) -> None:
        loc = _rewrite_remote_location("/remote/6/remote/6/cgi-bin/luci/admin/", 6)
        self.assertEqual(loc, "/remote/6/cgi-bin/luci/admin/")

    def test_build_response_multiple_set_cookie(self) -> None:
        resp = _build_response(
            b"ok",
            200,
            [
                ("Content-Type", "text/html"),
                ("Set-Cookie", "a=1; Path=/cgi-bin/luci/"),
                ("Set-Cookie", "b=2; Path=/cgi-bin/luci/"),
            ],
        )
        self.assertIsInstance(resp, Response)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.headers.getlist("set-cookie"), ["a=1; Path=/cgi-bin/luci/", "b=2; Path=/cgi-bin/luci/"])

    def test_upstream_cookie_strips_platform_auth(self) -> None:
        from starlette.requests import Request

        scope = {
            "type": "http",
            "headers": [(b"cookie", b"gfc_remote_6=jwt; sysauth=abc")],
            "method": "GET",
            "path": "/",
        }
        req = Request(scope)
        out = _upstream_cookie(req, 6)
        self.assertNotIn("gfc_remote_6", out)
        self.assertIn("sysauth=abc", out)

    def test_remote_auth_cookie_name(self) -> None:
        self.assertEqual(_remote_auth_cookie_name(6), "gfc_remote_6")

    def test_normalize_ubus_paths(self) -> None:
        self.assertEqual(_normalize_luci_path("admin/gfc/status/ubus"), "admin/ubus")
        self.assertEqual(_normalize_cgi_path("luci/admin/gfc/status/ubus"), "luci/admin/ubus")
        self.assertEqual(_normalize_luci_path("admin/network/wifi"), "admin/network/wifi")

    def test_parse_remote_device_id(self) -> None:
        ref = "http://103.78.41.16:5173/remote/6/cgi-bin/luci/admin/gfc/config/policy"
        self.assertEqual(_parse_remote_device_id(ref), 6)
        self.assertIsNone(_parse_remote_device_id("http://example.com/admin"))

    def test_inject_luci_patches_transport(self) -> None:
        html = "<html><head></head><body></body></html>"
        out = _inject_luci_remote_base(html, 6)
        self.assertIn("XMLHttpRequest.prototype.open", out)
        self.assertIn("fixUrl", out)
        self.assertIn("Authorization", out)
        self.assertIn('data-gfc-remote="6"', out)


if __name__ == "__main__":
    unittest.main()
