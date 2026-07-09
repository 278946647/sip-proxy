import { Button, Space, Typography, message } from "antd";
import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { getToken } from "../api/auth";
import { websshUrl } from "../lib/reverseSsh";

export function ClientWebSSHPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const termRef = useRef<HTMLPreElement>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const [phase, setPhase] = useState<"connecting" | "shell" | "failed">("connecting");

  useEffect(() => {
    if (!id) return;
    const token = getToken();
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
  }, [id, nav]);

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

  return (
    <div>
      <Space style={{ marginBottom: 12 }}>
        <Button onClick={() => nav(`/client-devices/${id}`)}>返回设备详情</Button>
        <Typography.Text
          type={phase === "shell" ? "success" : phase === "failed" ? "danger" : "secondary"}
        >
          {phase === "shell" ? "Shell 已连接" : phase === "failed" ? "连接失败" : "连接中…"}
        </Typography.Text>
      </Space>
      <Typography.Title level={5}>远程 SSH — 设备 #{id}</Typography.Title>
      <pre
        ref={termRef}
        tabIndex={0}
        style={{
          background: "#0f172a",
          color: "#e2e8f0",
          padding: 16,
          minHeight: 480,
          overflow: "auto",
          borderRadius: 8,
          fontFamily: "Consolas, monospace",
          fontSize: 13,
        }}
      />
      <Typography.Paragraph type="secondary" style={{ marginTop: 8 }}>
        点击终端区域后可直接输入。需在控制平台配置{" "}
        <code>GFC_REVERSE_SSH_CLIENT_SHELL_PASSWORD</code>（设备 root 密码）或密钥路径；
        并确认反向隧道已就绪。
      </Typography.Paragraph>
      <Link to="/client-devices">返回客户端列表</Link>
    </div>
  );
}
