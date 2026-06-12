import { ArrowLeftOutlined, DeleteOutlined } from "@ant-design/icons";
import { Button, Card, Col, Popconfirm, Progress, Row, Space, Statistic, Tag, Typography, message } from "antd";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import dayjs from "dayjs";
import { apiDelete, apiGet } from "../api/client";
import { mapClientDeviceDetail, type ClientDeviceDetail } from "../types";

function pct(n: number | undefined, fallback = 0) {
  return typeof n === "number" && !Number.isNaN(n) ? n : fallback;
}

export function ClientDeviceDetailPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [device, setDevice] = useState<ClientDeviceDetail | null>(null);

  const load = async () => {
    const raw = await apiGet<Record<string, unknown>>(`/admin/client-devices/${id}`);
    setDevice(mapClientDeviceDetail(raw));
  };

  const removeDevice = async () => {
    if (!id) return;
    try {
      const res = await apiDelete<{ ok: boolean; message?: string }>(
        `/admin/client-devices/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`
      );
      message.success(res.message || "已删除");
      nav("/client-devices");
    } catch (e) {
      message.error(String(e));
    }
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
    const timer = window.setInterval(() => void load().catch(() => undefined), 15000);
    return () => window.clearInterval(timer);
  }, [id]);

  if (!device) return null;

  const m = device.metrics ?? {};
  const memPct =
    m.memoryUsedMb && m.memoryTotalMb ? (m.memoryUsedMb / m.memoryTotalMb) * 100 : undefined;

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/client-devices")}>
          返回列表
        </Button>
        {device.lineId && (
          <Link to={`/lines/${device.lineId}`}>
            <Button type="link">查看关联线路</Button>
          </Link>
        )}
        {device.reverseSshPort && (
          <Button type="primary" onClick={() => message.info(`SSH 反代端口：${device.reverseSshPort}`)}>
            远程连接
          </Button>
        )}
        <Popconfirm
          title="删除此客户端？"
          description="在线设备将凭线路码自动重新注册。"
          onConfirm={() => void removeDevice()}
        >
          <Button danger icon={<DeleteOutlined />}>
            删除
          </Button>
        </Popconfirm>
      </Space>

      <Typography.Title level={4}>
        {device.name}{" "}
        <Tag color={device.online ? "green" : "red"} style={{ verticalAlign: "middle" }}>
          {device.online ? "在线" : "离线"}
        </Tag>
      </Typography.Title>

      <Typography.Paragraph type="secondary">
        设备 ID：{device.deviceId || device.deviceKey} | MAC：{device.lanMac || "-"} | 代理模式：
        {device.proxyMode} | 节点：{device.nodeName || "-"} | 最后在线：
        {device.lastSeenAt ? dayjs(device.lastSeenAt).format("YYYY-MM-DD HH:mm:ss") : "-"}
      </Typography.Paragraph>

      <Row gutter={[16, 16]}>
        <Col xs={24} md={8}>
          <Card title="CPU">
            <Progress
              type="dashboard"
              percent={pct(m.cpuPercent)}
              format={(p) => `${p?.toFixed(1)}%`}
            />
            <div style={{ textAlign: "center", color: "#64748b" }}>{m.cpuCores ?? "-"} 核</div>
          </Card>
        </Col>
        <Col xs={24} md={8}>
          <Card title="内存">
            <Progress
              type="dashboard"
              percent={pct(memPct)}
              strokeColor="#722ed1"
              format={(p) => `${p?.toFixed(1)}%`}
            />
            <div style={{ textAlign: "center", color: "#64748b" }}>
              {m.memoryUsedMb ?? "-"} MB / {m.memoryTotalMb ?? "-"} MB
            </div>
          </Card>
        </Col>
        <Col xs={24} md={8}>
          <Card title="连接数">
            <Statistic value={m.connectionCount ?? 0} suffix="条" />
          </Card>
        </Col>
        <Col xs={24} md={12}>
          <Card title="网络速率">
            <Row gutter={16}>
              <Col span={12}>
                <Statistic
                  title="上行"
                  value={pct(m.uploadMbps)}
                  precision={2}
                  suffix="Mbps"
                />
                <Typography.Text type="secondary">
                  峰值 {pct(m.uploadPeakMbps).toFixed(2)} Mbps
                </Typography.Text>
              </Col>
              <Col span={12}>
                <Statistic
                  title="下行"
                  value={pct(m.downloadMbps)}
                  precision={2}
                  suffix="Mbps"
                />
                <Typography.Text type="secondary">
                  峰值 {pct(m.downloadPeakMbps).toFixed(2)} Mbps
                </Typography.Text>
              </Col>
            </Row>
          </Card>
        </Col>
      </Row>
    </div>
  );
}
