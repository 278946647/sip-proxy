import { Button, Typography, message } from "antd";
import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { getToken } from "../api/auth";
import { websshUrl } from "../lib/reverseSsh";

export function ClientWebSSHPage() {
  const { id } = useParams();
  const [search] = useSearchParams();
  const nav = useNavigate();
  const termRef = useRef<HTMLPreElement>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [phase, setPhase] = useState<"connecting" | "shell" | "failed">("connecting");

  useEffect(() => {
    if (!id) return;
    const token = search.get("token") || getToken();
    if (!token) {
      message.error("未登录");
      nav("/login");
      return;
    }
    const ws = new WebSocket(websshUrl(Number(id)));
    ws.binaryType = "arraybuffer";
    wsRef.current = ws;
    ws.onopen = () => {
      append("\r\n[正在连接设备 Shell…]\r\n");
    };
    ws.onmessage = (ev) => {
      const text =
        typeof ev.data === "string" ? ev.data : new TextDecoder().decode(ev.data);
      append(text);
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
      append("\r\n[连接已关闭]\r\n");
    };
    ws.onerror = () => {
      setPhase("failed");
      message.error("WebSSH 连接失败");
    };
    return () => ws.close();
  }, [id, nav, search]);

  const append = (text: string) => {
    const el = termRef.current;
    if (!el) return;
    el.textContent = (el.textContent || "") + text;
    el.scrollTop = el.scrollHeight;
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const ws = wsRef.current;
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      if (e.key.length === 1) {
        ws.send(e.key);
        e.preventDefault();
      } else if (e.key === "Enter") {
        ws.send("\r");
        e.preventDefault();
      } else if (e.key === "Backspace") {
        ws.send("\x7f");
        e.preventDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

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
      <pre
        ref={termRef}
        tabIndex={0}
        style={{
          flex: 1,
          margin: 0,
          background: "#0f172a",
          color: "#e2e8f0",
          padding: 12,
          overflow: "auto",
          fontFamily: "Consolas, monospace",
          fontSize: 13,
          outline: "none",
        }}
      />
    </div>
  );
}
