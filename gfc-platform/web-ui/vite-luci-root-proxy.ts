import type { Plugin } from "vite";
import http from "node:http";
import { URL } from "node:url";

const ROOT_PATH_RE = /^\/(cgi-bin|luci-static|gfc)\//;

function parseDeviceId(referer: string): string | null {
  const m = referer.match(/\/remote\/(\d+)(?:\/|$)/);
  return m ? m[1] : null;
}

/** Dev-server shim: proxy bare /cgi-bin/ and /luci-static/ using Referer device id. */
export function luciRootProxy(apiTarget: string): Plugin {
  return {
    name: "gfc-luci-root-proxy",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const raw = req.url ?? "";
        const pathname = raw.split("?")[0];
        if (!ROOT_PATH_RE.test(pathname)) {
          return next();
        }

        const deviceId = parseDeviceId(String(req.headers.referer ?? ""));
        if (!deviceId) {
          res.statusCode = 404;
          res.setHeader("Content-Type", "text/plain; charset=utf-8");
          res.end("LuCI root path requires active /remote/{device}/ session");
          return;
        }

        const upstream = new URL(`/remote/${deviceId}${raw}`, apiTarget);
        const headers: http.OutgoingHttpHeaders = { ...req.headers };
        headers.host = upstream.host;

        const proxyReq = http.request(
          upstream,
          { method: req.method, headers },
          (proxyRes) => {
            res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers);
            proxyRes.pipe(res);
          },
        );
        proxyReq.on("error", (err) => {
          if (!res.headersSent) {
            res.statusCode = 502;
            res.end(`upstream error: ${err.message}`);
          }
        });
        req.pipe(proxyReq);
      });
    },
  };
}
