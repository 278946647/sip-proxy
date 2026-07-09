import { Button, Typography, message } from "antd";
import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { getToken, getUser } from "../api/auth";
import { permissionsFromUser } from "../utils/permissions";
import { websshUrl } from "../lib/reverseSsh";
import "@xterm/xterm/css/xterm.css";

export function ClientWebSSHPage() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const nav = useNavigate();
  const hostRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [phase, setPhase] = useState<"connecting" | "shell" | "failed">("connecting");

  useEffect(() => {
    if (!permissionsFromUser(getUser()).canRemoteAccess) {
      message.error("当前角色无权使用远程 Shell");
      nav("/client-devices");
      return;
    }
    if (!id || !hostRef.current) return;
    const token = search.get("token") || getToken();
    if (!token) {
      message.error("未登录");
      nav("/login");
      return;
    }

    const term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "Consolas, 'Courier New', monospace",
      theme: {
        background: "#0f172a",
        foreground: "#e2e8f0",
        cursor: "#e2e8f0",
      },
      allowProposedApi: true,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(hostRef.current);
    fitAddon.fit();
    termRef.current = term;
    fitRef.current = fitAddon;

    const onResize = () => fitAddon.fit();
    window.addEventListener("resize", onResize);

    term.writeln("[正在连接设备 Shell…]");

    const ws = new WebSocket(websshUrl(Number(id)));
    ws.binaryType = "arraybuffer";
    wsRef.current = ws;

    ws.onopen = () => {
      term.focus();
    };

    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") {
        term.write(ev.data);
      } else {
        term.write(new Uint8Array(ev.data));
      }
      const text = typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data);
      if (
        text.includes("Permission denied") ||
        text.includes("未配置设备 Shell") ||
        text.includes("[webssh]")
      ) {
        setPhase("failed");
      } else if (
        text.includes("BusyBox") ||
        /root@/.test(text) ||
        text.includes("ImmortalWrt")
      ) {
        setPhase("shell");
      }
    };

    ws.onclose = () => {
      setPhase((p) => (p === "shell" ? "shell" : "failed"));
      term.writeln("\r\n[连接已关闭]");
    };

    ws.onerror = () => {
      setPhase("failed");
      message.error("WebSSH 连接失败");
    };

    const dataDisposable = term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(new TextEncoder().encode(data));
      }
    });

    return () => {
      dataDisposable.dispose();
      window.removeEventListener("resize", onResize);
      ws.close();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
      wsRef.current = null;
    };
  }, [id, nav, search]);

  const statusText =
    phase === "shell" ? "Shell 已连接" : phase === "failed" ? "连接失败" : "连接中…";
  const statusColor =
    phase === "shell" ? "#22c55e" : phase === "failed" ? "#ef4444" : "#94a3b8";

  return (
    <div
      style={{
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        background: "#0b1220",
        color: "#e2e8f0",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "8px 12px",
          borderBottom: "1px solid #1e293b",
          background: "#111827",
          flexShrink: 0,
        }}
      >
        <Typography.Text style={{ color: "#e2e8f0", fontSize: 13 }}>
          远程 SSH — 设备 #{id}
        </Typography.Text>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <span style={{ color: statusColor, fontSize: 12 }}>{statusText}</span>
          <Button size="small" onClick={() => window.close()}>
            关闭
          </Button>
        </div>
      </div>
      <div
        ref={hostRef}
        style={{
          flex: 1,
          minHeight: 0,
          padding: 4,
          background: "#0f172a",
        }}
      />
    </div>
  );
}
