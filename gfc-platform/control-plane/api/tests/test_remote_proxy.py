import unittest

from app.remote_proxy import (
    _rewrite_remote_location,
    _rewrite_set_cookie,
    _rewrite_text_paths,
)


class RemoteProxyRewriteTest(unittest.TestCase):
    def test_rewrite_text_paths_quotes(self) -> None:
        text = 'src="/luci-static/luci.js" fetch(\'/cgi-bin/luci/admin/ubus\')'
        out = _rewrite_text_paths(text, 6)
        self.assertIn('/remote/6/luci-static/', out)
        self.assertIn('/remote/6/cgi-bin/', out)
        self.assertNotIn('/remote/6/remote/6/', out)

    def test_rewrite_text_paths_json_escaped(self) -> None:
        text = '{"media":"\\/luci-static\\/openwrt.org","path":"\\/cgi-bin\\/luci"}'
        out = _rewrite_text_paths(text, 6)
        self.assertIn("\\/remote\\/6\\/luci-static\\/", out)
        self.assertIn("\\/remote\\/6\\/cgi-bin\\/", out)

    def test_rewrite_text_paths_luci_base(self) -> None:
        text = 'L = new LuCI({ url: "/cgi-bin/luci" });'
        out = _rewrite_text_paths(text, 6)
        self.assertIn('"/remote/6/cgi-bin/luci"', out)

    def test_rewrite_text_paths_css_url(self) -> None:
        text = "background:url(/luci-static/foo.css)"
        out = _rewrite_text_paths(text, 7)
        self.assertIn("url(/remote/7/luci-static/foo.css)", out)

    def test_rewrite_set_cookie_path(self) -> None:
        raw = "sysauth=abc; Path=/cgi-bin/luci/; HttpOnly"
        out = _rewrite_set_cookie(raw, 6)
        self.assertIn("Path=/remote/6/cgi-bin/luci/", out)

    def test_rewrite_location(self) -> None:
        loc = _rewrite_remote_location("/cgi-bin/luci/admin/", 6)
        self.assertEqual(loc, "/remote/6/cgi-bin/luci/admin/")


if __name__ == "__main__":
    unittest.main()
