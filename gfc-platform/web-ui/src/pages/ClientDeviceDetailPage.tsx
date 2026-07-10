import { ArrowLeftOutlined, DeleteOutlined } from "@ant-design/icons";
import {
  Alert,
  Button,
  Card,
  Col,
  Descriptions,
  Input,
  Modal,
  Progress,
  Radio,
  Row,
  Select,
  Space,
  Statistic,
  Tag,
  Typography,
  message,
} from "antd";
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { formatApiTime, formatApiTimeFromNow } from "../utils/datetime";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { openRemoteTarget } from "../lib/openRemote";
import { confirmDeleteClientDevice } from "../utils/dangerousConfirm";
import {
  confirmClientLineChange,
  confirmClientLineUnbind,
  confirmRoutingSchemeChange,
} from "../utils/clientLineConfirm";
import { getUser } from "../api/auth";
import { canWrite, isOperatorDeletableClient, permissionsFromUser } from "../utils/permissions";
import {
  lineBindingLabel,
  mapClientDeviceDetail,
  mapLineItem,
  type ClientDeviceDetail,
  type DeviceProxyMode,
  type DeviceRoutingScheme,
  type LineListItem,
} from "../types";

const SERVICE_REASON_LABEL: Record<string, string> = {
  line_disabled: "线路已禁用",
  line_deleted: "线路已删除",
  line_unbound: "未绑线",
  node_offline: "节点离线",
  agent_not_active: "Agent 未就绪",
};

const PROXY_MODE_LABEL: Record<DeviceProxyMode, string> = {
  gateway: "网关模式",
  bypass: "旁路模式",
  transparent: "透明模式",
};

const ROUTING_SCHEME_LABEL: Record<DeviceRoutingScheme, string> = {
  split: "分流模式",
  global: "全局模式",
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

function pct(n: number | undefined) {
  return typeof n === "number" && !Number.isNaN(n) ? n : undefined;
}

function formatMbps(n: number | undefined) {
  if (n == null || Number.isNaN(n)) return "—";
  return `${n.toFixed(2)} Mbps`;
}

function metricDashPercent(n: number | undefined) {
  return pct(n) ?? 0;
}

export function ClientDeviceDetailPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [device, setDevice] = useState<ClientDeviceDetail | null>(null);
  const [lines, setLines] = useState<LineListItem[]>([]);
  const [nameDraft, setNameDraft] = useState("");
  const [routingDraft, setRoutingDraft] = useState<DeviceRoutingScheme>("split");
  const [lineModalOpen, setLineModalOpen] = useState(false);
  const [lineDraft, setLineDraft] = useState<number | undefined>();
  const [savingName, setSavingName] = useState(false);
  const [savingRouting, setSavingRouting] = useState(false);
  const perms = permissionsFromUser(getUser());
  const writable = canWrite(getUser());

  const load = async () => {
    const raw = await apiGet<Record<string, unknown>>(`/admin/client-devices/${id}`);
    const mapped = mapClientDeviceDetail(raw);
    setDevice(mapped);
    setNameDraft(mapped.name);
    setRoutingDraft(mapped.routingScheme);
  };

  const loadLines = async () => {
    const lineRes = await apiGet<{ total: number; items: Record<string, unknown>[] }>(
      "/admin/lines?page_size=200"
    );
    setLines(lineRes.items.map(mapLineItem));
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
    void loadLines().catch(() => undefined);
    const timer = window.setInterval(() => void load().catch(() => undefined), 15000);
    return () => window.clearInterval(timer);
  }, [id]);

  const clientLines = useMemo(
    () => lines.filter((l) => l.lineType === "client"),
    [lines]
  );

  const currentLineLabel = useMemo(() => {
    if (!device?.lineId) return "未绑线";
    return lineBindingLabel(device.lineTid, device.nodeName, device.lineCountry);
  }, [device]);

  const saveName = async () => {
    if (!device || !id) return;
    const trimmed = nameDraft.trim();
    if (!trimmed) {
      message.warning("设备名称不能为空");
      return;
    }
    setSavingName(true);
    try {
      await apiPatch(
        `/admin/client-devices/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`,
        { name: trimmed }
      );
      message.success("设备名称已保存");
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setSavingName(false);
    }
  };

  const applyLineChange = async (lineId: number | null) => {
    if (!device || !id) return;
    try {
      await apiPatch(
        `/admin/client-devices/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`,
        { line_id: lineId }
      );
      message.success("线路关联已更新，客户端将在下次拉取配置后生效");
      setLineModalOpen(false);
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const openLineChangeModal = () => {
    setLineDraft(device?.lineId ?? undefined);
    setLineModalOpen(true);
  };

  const confirmLineChange = () => {
    if (!device) return;
    const targetLine = clientLines.find((l) => l.id === lineDraft);
    if (!targetLine) {
      message.warning("请选择目标线路");
      return;
    }
    if (targetLine.id === device.lineId) {
      setLineModalOpen(false);
      return;
    }
    const toLabel = lineBindingLabel(targetLine.tid, targetLine.nodeName, targetLine.country);
    confirmClientLineChange(device.name, currentLineLabel, toLabel, () =>
      applyLineChange(targetLine.id)
    );
  };

  const confirmUnbind = () => {
    if (!device || !device.lineId) return;
    confirmClientLineUnbind(device.name, currentLineLabel, () => applyLineChange(null));
  };

  const saveRoutingScheme = () => {
    if (!device || !id) return;
    if (routingDraft === device.routingScheme) return;
    confirmRoutingSchemeChange(
      device.name,
      ROUTING_SCHEME_LABEL[device.routingScheme],
      ROUTING_SCHEME_LABEL[routingDraft],
      async () => {
        setSavingRouting(true);
        try {
          await apiPatch(
            `/admin/client-devices/${id}?operator=${localStorage.getItem("gfc_user") || "admin"}`,
            { routing_scheme: routingDraft }
          );
          message.success("代理模式已保存");
          await load();
        } catch (e) {
          message.error(String(e));
        } finally {
          setSavingRouting(false);
        }
      }
    );
  };

  if (!device) return null;

  const m = device.metrics;
  const memPct = pct(m?.memoryPercent) ?? (m?.memoryUsedMb && m?.memoryTotalMb
    ? (m.memoryUsedMb / m.memoryTotalMb) * 100
    : undefined);
  const metricsOnline = device.managementState === "online";
  const hasMetrics = metricsOnline && m != null;

  return (
    <div>
      <Space style={{ marginBottom: 16 }} wrap>
        <Button icon={<ArrowLeftOutlined />} onClick={() => nav("/client-devices")}>
          返回列表
        </Button>
        {perms.canRemoteAccess && device.reverseSshPort && device.sshPublicKeyRegistered && device.managementState === "online" && (
          <Space>
            <Button type="primary" onClick={() => void openRemoteTarget(device.id, "ssh", device.name)}>
              远程 SSH
            </Button>
            <Button onClick={() => void openRemoteTarget(device.id, "web", device.name)}>Web 管理</Button>
            <Button onClick={() => void openRemoteTarget(device.id, "flash", device.name)}>刷码协助</Button>
          </Space>
        )}
        {perms.canDeleteStructural || isOperatorDeletableClient(device) ? (
          <Button
            danger
            icon={<DeleteOutlined />}
            onClick={() => confirmDeleteClientDevice(device.name, () => removeDevice())}
          >
            删除
          </Button>
        ) : null}
      </Space>

      <Space align="center" style={{ marginBottom: 8 }} wrap>
        {writable ? (
          <Input
            value={nameDraft}
            onChange={(e) => setNameDraft(e.target.value)}
            style={{ width: 280, fontSize: 18, fontWeight: 600 }}
          />
        ) : (
          <Typography.Title level={4} style={{ margin: 0 }}>
            {device.name}
          </Typography.Title>
        )}
        {writable && nameDraft.trim() !== device.name ? (
          <Button type="primary" size="small" loading={savingName} onClick={() => void saveName()}>
            保存名称
          </Button>
        ) : null}
        <Tag color={device.managementState === "online" ? "green" : "red"}>
          {device.managementState === "online" ? "在线" : "离线"}
        </Tag>
        {serviceTag(device)}
      </Space>

      <Typography.Paragraph type="secondary" style={{ marginBottom: 16 }}>
        设备 ID：{device.deviceId || device.deviceKey} | Agent：{device.agentVersion || "-"} |
        最后在线：
        {device.lastSeenAt
          ? `${formatApiTime(device.lastSeenAt)} (${formatApiTimeFromNow(device.lastSeenAt)})`
          : "-"}
        {device.serviceReason ? (
          <> | 关停原因：{SERVICE_REASON_LABEL[device.serviceReason] ?? device.serviceReason}</>
        ) : null}
      </Typography.Paragraph>

      <Row gutter={[16, 16]}>
        <Col xs={24} lg={12}>
          <Card title="关联线路">
            {device.lineId ? (
              <Descriptions column={1} size="small">
                <Descriptions.Item label="线路">
                  {lineBindingLabel(device.lineTid, device.nodeName, device.lineCountry)}
                </Descriptions.Item>
                {device.lineName ? (
                  <Descriptions.Item label="名称">{device.lineName}</Descriptions.Item>
                ) : null}
                <Descriptions.Item label="状态">
                  {device.lineEnabled === false ? (
                    <Tag color="orange">已禁用</Tag>
                  ) : (
                    <Tag color="green">已启用</Tag>
                  )}
                </Descriptions.Item>
              </Descriptions>
            ) : (
              <Typography.Text type="secondary">当前未绑定线路，设备处于直连管控模式。</Typography.Text>
            )}
            <Space style={{ marginTop: 12 }}>
              {device.lineId ? (
                <Link to={`/lines/${device.lineId}`}>
                  <Button type="link" style={{ padding: 0 }}>
                    查看线路详情
                  </Button>
                </Link>
              ) : null}
              {perms.actions.includes("write_critical") ? (
                <>
                  <Button size="small" onClick={openLineChangeModal}>
                    更换线路
                  </Button>
                  {device.lineId ? (
                    <Button size="small" danger onClick={confirmUnbind}>
                      解绑线路
                    </Button>
                  ) : null}
                </>
              ) : null}
            </Space>
          </Card>
        </Col>

        <Col xs={24} lg={12}>
          <Card title="代理模式">
            <Radio.Group
              value={routingDraft}
              onChange={(e) => setRoutingDraft(e.target.value)}
              disabled={!writable}
              style={{ display: "flex", flexDirection: "column", gap: 8 }}
            >
              <Radio value="split">
                <Typography.Text strong>分流模式</Typography.Text>
                <div style={{ color: "#64748b", fontSize: 13, marginLeft: 24 }}>
                  国内直连，国际流量走代理（默认）
                </div>
              </Radio>
              <Radio value="global">
                <Typography.Text strong>全局模式</Typography.Text>
                <div style={{ color: "#64748b", fontSize: 13, marginLeft: 24 }}>
                  全部流量走国际出口
                </div>
              </Radio>
            </Radio.Group>
            {writable && routingDraft !== device.routingScheme ? (
              <Button
                type="primary"
                size="small"
                style={{ marginTop: 12 }}
                loading={savingRouting}
                onClick={saveRoutingScheme}
              >
                保存代理模式
              </Button>
            ) : null}
          </Card>
        </Col>

        <Col xs={24}>
          <Card
            title="运行指标"
            extra={
              hasMetrics && m?.updatedAt ? (
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  更新于 {formatApiTime(m.updatedAt, "HH:mm:ss")}
                </Typography.Text>
              ) : (
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  {metricsOnline ? "等待设备上报" : "设备离线"}
                </Typography.Text>
              )
            }
          >
            <Row gutter={[16, 16]}>
              <Col xs={24} sm={12} md={6}>
                <Card type="inner" title="CPU">
                  <Statistic
                    value={hasMetrics ? (pct(m?.cpuPercent)?.toFixed(1) ?? "—") : "—"}
                    suffix={hasMetrics && m?.cpuPercent != null ? "%" : undefined}
                  />
                  <Progress
                    type="dashboard"
                    size={80}
                    percent={metricDashPercent(m?.cpuPercent)}
                    format={(p) => (hasMetrics && m?.cpuPercent != null ? `${p?.toFixed(0)}%` : "—")}
                    style={{ marginTop: 8 }}
                  />
                </Card>
              </Col>
              <Col xs={24} sm={12} md={6}>
                <Card type="inner" title="内存">
                  <Statistic
                    value={
                      hasMetrics && m?.memoryUsedMb != null && m?.memoryTotalMb != null
                        ? `${m.memoryUsedMb} / ${m.memoryTotalMb}`
                        : "—"
                    }
                    suffix={hasMetrics && m?.memoryUsedMb != null ? "MB" : undefined}
                  />
                  <Progress
                    type="dashboard"
                    size={80}
                    percent={metricDashPercent(memPct)}
                    strokeColor="#722ed1"
                    format={(p) => (hasMetrics && memPct != null ? `${p?.toFixed(0)}%` : "—")}
                    style={{ marginTop: 8 }}
                  />
                </Card>
              </Col>
              <Col xs={24} sm={12} md={6}>
                <Card type="inner" title="连接数">
                  <Statistic
                    value={hasMetrics && m?.connectionCount != null ? m.connectionCount : "—"}
                    suffix={hasMetrics && m?.connectionCount != null ? "条" : undefined}
                  />
                </Card>
              </Col>
              <Col xs={24} sm={12} md={6}>
                <Card type="inner" title="隧道流量">
                  <div style={{ marginBottom: 8 }}>
                    <Typography.Text type="secondary">下行 </Typography.Text>
                    {formatMbps(m?.downloadMbps)}
                  </div>
                  <div>
                    <Typography.Text type="secondary">上行 </Typography.Text>
                    {formatMbps(m?.uploadMbps)}
                  </div>
                </Card>
              </Col>
            </Row>
          </Card>
        </Col>

        <Col xs={24}>
          <Card title="远程接入与设备信息">
            <Descriptions column={{ xs: 1, sm: 2 }} size="small">
              <Descriptions.Item label="LAN MAC">
                <Typography.Text code copyable={!!device.lanMac}>
                  {device.lanMac || "-"}
                </Typography.Text>
              </Descriptions.Item>
              <Descriptions.Item label="路由工作模式">
                {PROXY_MODE_LABEL[device.proxyMode] ?? device.proxyMode}
              </Descriptions.Item>
              <Descriptions.Item label="代理模式">
                {ROUTING_SCHEME_LABEL[device.routingScheme]}
              </Descriptions.Item>
              <Descriptions.Item label="反代 SSH 端口">
                <Typography.Text code>{device.reverseSshPort ?? "-"}</Typography.Text>
              </Descriptions.Item>
              <Descriptions.Item label="反代 HTTP 端口">
                <Typography.Text code>{device.reverseHttpPort ?? "-"}</Typography.Text>
              </Descriptions.Item>
              <Descriptions.Item label="SSH 公钥">
                {device.sshPublicKeyRegistered ? (
                  <Tag color="green">已注册</Tag>
                ) : (
                  <Tag color="warning">未注册</Tag>
                )}
              </Descriptions.Item>
              <Descriptions.Item label="反代会话">
                {device.reverseSshSessionState || "idle"}
              </Descriptions.Item>
            </Descriptions>
            {!device.sshPublicKeyRegistered ? (
              <Alert
                type="warning"
                showIcon
                style={{ marginTop: 12 }}
                message="设备尚未注册 SSH 公钥，远程接入不可用。"
              />
            ) : null}
          </Card>
        </Col>
      </Row>

      <Modal
        title="更换关联线路"
        open={lineModalOpen}
        onCancel={() => setLineModalOpen(false)}
        onOk={confirmLineChange}
        okText="确认更换"
        cancelText="取消"
      >
        <Typography.Paragraph type="secondary">
          当前：{currentLineLabel}
        </Typography.Paragraph>
        <Select
          showSearch
          placeholder="选择目标线路"
          style={{ width: "100%" }}
          value={lineDraft}
          onChange={setLineDraft}
          optionFilterProp="label"
          options={clientLines.map((l) => ({
            label: `${lineBindingLabel(l.tid, l.nodeName, l.country)}${!l.isEnabled ? " (已禁用)" : ""}${
              l.clientDeviceId && l.clientDeviceId !== device.id ? " (已占用)" : ""
            }`,
            value: l.id,
            disabled: !!l.clientDeviceId && l.clientDeviceId !== device.id,
          }))}
        />
      </Modal>
    </div>
  );
}
