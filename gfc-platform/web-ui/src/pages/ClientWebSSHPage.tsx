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
  const [connected, setConnected] = useState(false);

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
      setConnected(true);
      append("\r\n[已连接远程 SSH]\r\n");
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") append(ev.data);
      else append(new TextDecoder().decode(ev.data));
    };
    ws.onclose = () => {
      setConnected(false);
      append("\r\n[连接已关闭]\r\n");
    };
    ws.onerror = () => message.error("WebSSH 连接失败");
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
        <Typography.Text type={connected ? "success" : "secondary"}>
          {connected ? "已连接" : "连接中…"}
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
        点击终端区域后可直接输入。若无法连接，请确认控制平台已安装 <code>ssh</code> 客户端且设备隧道已就绪。
      </Typography.Paragraph>
      <Link to="/client-devices">返回客户端列表</Link>
    </div>
  );
}
