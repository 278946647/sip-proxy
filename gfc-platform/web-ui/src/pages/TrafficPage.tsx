import {
  Button,
  Card,
  DatePicker,
  Form,
  Input,
  InputNumber,
  Modal,
  Progress,
  Space,
  Table,
  Tag,
  Typography,
  message,
} from "antd";
import { ReloadOutlined, SettingOutlined } from "@ant-design/icons";
import { useCallback, useEffect, useMemo, useState } from "react";
import { formatApiTime, nowDisplay, parseApiTime, toApiIso } from "../utils/datetime";
import { apiGet, apiPatch, apiPost } from "../api/client";
import { formatBytes } from "../components/TrafficChart";
import { mapNodeTrafficOverview, quotaPercentInt, type NodeTrafficOverview } from "../types";
import { getUser } from "../api/auth";
import { permissionsFromUser } from "../utils/permissions";

function maskIp(ip: string | null) {
  if (!ip) return "-";
  const parts = ip.split(".");
  if (parts.length !== 4) return ip;
  return `${parts[0]}.${parts[1]}.***.***`;
}

function statusTag(status: string) {
  if (status === "active") return <Tag color="green">活跃</Tag>;
  if (status === "offline") return <Tag color="red">离线</Tag>;
  return <Tag>无数据</Tag>;
}

export function TrafficPage() {
  const [rows, setRows] = useState<NodeTrafficOverview[]>([]);
  const perms = permissionsFromUser(getUser());
  const [loading, setLoading] = useState(false);
  const [lastRefresh, setLastRefresh] = useState(nowDisplay());
  const [editOpen, setEditOpen] = useState(false);
  const [editing, setEditing] = useState<NodeTrafficOverview | null>(null);
  const [saving, setSaving] = useState(false);
  const [form] = Form.useForm();

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await apiGet<Record<string, unknown>[]>("/admin/node-traffic/overview");
      setRows(res.map(mapNodeTrafficOverview));
      setLastRefresh(nowDisplay());
    } catch (e) {
      message.error(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(), 60_000);
    return () => window.clearInterval(timer);
  }, [load]);

  const lastCollectAt = useMemo(() => {
    const times = rows.map((r) => r.lastSampleAt).filter(Boolean) as string[];
    if (times.length === 0) return null;
    return times.sort().at(-1) ?? null;
  }, [rows]);

  const openEdit = (row: NodeTrafficOverview) => {
    setEditing(row);
    form.setFieldsValue({
      billingCycleStartAt: row.billingCycleStartAt ? parseApiTime(row.billingCycleStartAt) : nowDisplay(),
      billingCycleDays: row.billingCycleDays,
      monthlyQuotaGb: row.monthlyQuotaGb ?? undefined,
      correctionBytes: row.correctionBytes,
      monitorIface: row.monitorIface ?? undefined,
    });
    setEditOpen(true);
  };

  const saveBilling = async () => {
    if (!editing) return;
    const v = await form.validateFields();
    setSaving(true);
    try {
      await apiPatch(
        `/admin/nodes/${editing.nodeId}/traffic-billing?operator=${localStorage.getItem("gfc_user") || "admin"}`,
        {
          billing_cycle_start_at: toApiIso(v.billingCycleStartAt),
          billing_cycle_days: v.billingCycleDays,
          monthly_quota_gb: v.monthlyQuotaGb ?? null,
          correction_bytes: v.correctionBytes ?? 0,
          monitor_iface: v.monitorIface || null,
        }
      );
      message.success("计费配置已保存");
      setEditOpen(false);
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setSaving(false);
    }
  };

  const resetCycle = async () => {
    if (!editing) return;
    setSaving(true);
    try {
      await apiPost(
        `/admin/nodes/${editing.nodeId}/traffic-billing/reset-cycle?operator=${localStorage.getItem("gfc_user") || "admin"}`,
        {}
      );
      message.success("已开启新计费周期，用量从零累计");
      setEditOpen(false);
      await load();
    } catch (e) {
      message.error(String(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
        <div>
          <Typography.Title level={4} style={{ margin: 0 }}>
            端口流量概览
          </Typography.Title>
          <Typography.Text type="secondary">
            数据每 5 分钟自动采集
            {lastCollectAt ? ` | 最后采集：${formatApiTime(lastCollectAt)}` : ""}
          </Typography.Text>
        </div>
        <Button icon={<ReloadOutlined />} onClick={() => void load()}>
          刷新
        </Button>
      </div>

      <Card>
        <Table
          rowKey="nodeId"
          loading={loading}
          dataSource={rows}
          pagination={false}
          columns={[
            { title: "节点", dataIndex: "nodeName" },
            { title: "国家", dataIndex: "country", render: (v: string | null) => v || "-" },
            {
              title: "公网 IP",
              dataIndex: "publicIp",
              render: (v: string | null) => maskIp(v),
            },
            {
              title: "最近 24 小时",
              dataIndex: "last24hBytes",
              render: (v: number) => formatBytes(v),
            },
            {
              title: "最近增量 (7分钟)",
              dataIndex: "recentIncrementBytes",
              render: (v: number) => formatBytes(v),
            },
            {
              title: "计费周期用量",
              dataIndex: "billingPeriodBytes",
              render: (v: number, row) => (
                <Space direction="vertical" size={0}>
                  <span>{formatBytes(v)}</span>
                  {row.monthlyQuotaGb ? (
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      配额 {row.monthlyQuotaGb} GB
                    </Typography.Text>
                  ) : null}
                </Space>
              ),
            },
            {
              title: "流量用度",
              render: (_, row) => {
                if (!row.monthlyQuotaGb) {
                  return <Tag>无限制</Tag>;
                }
                const pct = quotaPercentInt(row.quotaUsedPercent);
                if (pct == null) return "—";
                return (
                  <Space direction="vertical" size={4} style={{ minWidth: 120 }}>
                    <Progress
                      percent={pct}
                      size="small"
                      status={pct >= 95 ? "exception" : "active"}
                      strokeColor={pct >= 85 && pct < 95 ? "#faad14" : undefined}
                      format={(p) => `${p}%`}
                    />
                  </Space>
                );
              },
            },
            {
              title: "状态",
              dataIndex: "status",
              render: (v: string) => statusTag(v),
            },
            {
              title: "操作",
              render: (_, row) =>
                perms.canWriteTrafficBilling ? (
                <Button size="small" icon={<SettingOutlined />} onClick={() => openEdit(row)}>
                  计费设置
                </Button>
                ) : null,
            },
          ]}
        />
      </Card>

      <Modal
        title={editing ? `计费设置 — ${editing.nodeName}` : "计费设置"}
        open={editOpen}
        onCancel={() => setEditOpen(false)}
        onOk={() => void saveBilling()}
        confirmLoading={saving}
        width={560}
        destroyOnClose
        footer={(_, { OkBtn, CancelBtn }) => (
          <Space style={{ width: "100%", justifyContent: "space-between" }}>
            <Button danger onClick={() => void resetCycle()} loading={saving}>
              开启新计费周期
            </Button>
            <Space>
              <CancelBtn />
              <OkBtn />
            </Space>
          </Space>
        )}
      >
        <Form form={form} layout="vertical">
          <Form.Item name="billingCycleStartAt" label="计费开始时间" rules={[{ required: true }]}>
            <DatePicker showTime style={{ width: "100%" }} />
          </Form.Item>
          <Form.Item name="billingCycleDays" label="计费周期（天）" rules={[{ required: true }]}>
            <InputNumber min={1} max={365} style={{ width: "100%" }} />
          </Form.Item>
          <Form.Item name="monthlyQuotaGb" label="月流量配额 (GB)">
            <InputNumber min={1} max={102400} placeholder="例如 5120 (=5TB)" style={{ width: "100%" }} />
          </Form.Item>
          <Form.Item
            name="correctionBytes"
            label="流量校正 (字节)"
            extra="用于补偿云厂商账单与采集偏差，计入当前计费周期"
          >
            <InputNumber style={{ width: "100%" }} />
          </Form.Item>
          <Form.Item name="monitorIface" label="监控网卡（可选）">
            <Input placeholder="留空则由节点 Agent 自动探测 WAN/TPROXY 网卡" />
          </Form.Item>
          {editing?.monthlyQuotaGb && editing.quotaUsedPercent != null ? (
            <Form.Item label="配额使用">
              <Progress
                percent={quotaPercentInt(editing.quotaUsedPercent) ?? 0}
                status={editing.quotaUsedPercent >= 95 ? "exception" : "active"}
                strokeColor={
                  editing.quotaUsedPercent >= 85 && editing.quotaUsedPercent < 95
                    ? "#faad14"
                    : undefined
                }
                format={(p) => `${p}%`}
              />
            </Form.Item>
          ) : null}
        </Form>
      </Modal>
    </div>
  );
}
