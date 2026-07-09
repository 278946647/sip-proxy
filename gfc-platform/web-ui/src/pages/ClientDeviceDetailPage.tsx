import { ArrowLeftOutlined, DeleteOutlined } from "@ant-design/icons";
import { Button, Card, Col, Progress, Row, Space, Statistic, Tag, Typography, message } from "antd";
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import dayjs from "dayjs";
import relativeTime from "dayjs/plugin/relativeTime";
import { apiDelete, apiGet } from "../api/client";
import { openRemoteTarget } from "../lib/openRemote";
import { confirmDeleteClientDevice } from "../utils/dangerousConfirm";
import { mapClientDeviceDetail, type ClientDeviceDetail } from "../types";

dayjs.extend(relativeTime);

const SERVICE_REASON_LABEL: Record<string, string> = {
  line_disabled: "线路已禁用",
  line_deleted: "线路已删除",
  line_unbound: "未绑线",
  node_offline: "节点离线",
  agent_not_active: "Agent 未就绪",
};

function serviceTag(item: ClientDeviceDetail) {
  const map: Record<ClientDeviceDetail["serviceState"], { color: string; label: string }> = {
    active: { color: "green", label: "业务正常" },
    suspended: { color: "orange", label: "业务关停" },
    unbound: { color: "default", label: "未绑线" },
    degraded: { color: "volcano", label: "业务异常" },
    unknown: { color: "default", label: "—" },
  };
  const meta = map[item.serviceState] ?? map.unknown;
  return <Tag color={meta.color}>{meta.label}</Tag>;
}

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
        `/admin/client-devices/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}&confirm=true`
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
        {device.reverseSshPort && device.sshPublicKeyRegistered && device.managementState === "online" && (
          <Space>
            <Button type="primary" onClick={() => void openRemoteTarget(device.id, "ssh", device.name)}>
              远程 SSH
            </Button>
            <Button onClick={() => void openRemoteTarget(device.id, "web", device.name)}>Web 管理</Button>
            <Button onClick={() => void openRemoteTarget(device.id, "flash", device.name)}>刷码协助</Button>
          </Space>
        )}
        <Button
          danger
          icon={<DeleteOutlined />}
          onClick={() => confirmDeleteClientDevice(device.name, () => removeDevice())}
        >
          删除
        </Button>
      </Space>

      <Typography.Title level={4}>
        {device.name}{" "}
        <Tag color={device.managementState === "online" ? "green" : "red"} style={{ verticalAlign: "middle" }}>
          {device.managementState === "online" ? "在线" : "离线"}
        </Tag>
        {serviceTag(device)}
      </Typography.Title>

      <Typography.Paragraph type="secondary">
        设备 ID：{device.deviceId || device.deviceKey} | MAC：{device.lanMac || "-"} | 代理模式：
        {device.proxyMode} | 节点：{device.nodeName || "-"} | 最后在线：
        {device.lastSeenAt ? `${dayjs(device.lastSeenAt).format("YYYY-MM-DD HH:mm:ss")} (${dayjs(device.lastSeenAt).fromNow()})` : "-"}
        {device.serviceReason ? (
          <>
            {" "}
            | 关停原因：{SERVICE_REASON_LABEL[device.serviceReason] ?? device.serviceReason}
          </>
        ) : null}
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
      </Row>
    </div>
  );
}
