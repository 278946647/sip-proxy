import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { luciRootProxy } from "./vite-luci-root-proxy";

const apiTarget = process.env.VITE_API_PROXY_TARGET || "http://localhost:8080";

export default defineConfig({
  plugins: [react(), luciRootProxy(apiTarget)],
  server: {
    host: "0.0.0.0",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": {
        target: apiTarget,
        changeOrigin: true,
        ws: true,
        rewrite: (p) => p.replace(/^\/api/, ""),
      },
      "/remote": {
        target: apiTarget,
        changeOrigin: true,
      },
    },
  },
});

