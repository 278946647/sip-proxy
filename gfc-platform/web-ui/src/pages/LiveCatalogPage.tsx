import {
  Button,
  Form,
  Input,
  Modal,
  Select,
  Space,
  Table,
  Tabs,
  Tag,
  Typography,
  message,
} from "antd";
import { CheckOutlined, CloseOutlined, PlusOutlined } from "@ant-design/icons";
import { useEffect, useMemo, useState } from "react";
import { formatApiTime } from "../utils/datetime";
import { apiDelete, apiGet, apiPatch, apiPost } from "../api/client";
import { getUser } from "../api/auth";
import { canWrite } from "../utils/permissions";
import type { LiveEndpointRow, LivePlatformRow, LiveCaptureCandidateRow } from "../types";

function mapPlatform(raw: Record<string, unknown>): LivePlatformRow {
  return {
    id: raw.id as string,
    displayName: raw.display_name as string,
    markets: (raw.markets as string[]) || [],
    liveStrength: (raw.live_strength as string) || "strong",
    isEnabled: raw.is_enabled !== false,
    endpointCount: (raw.endpoint_count as number) || 0,
    activeEndpointCount: (raw.active_endpoint_count as number) || 0,
    draftEndpointCount: (raw.draft_endpoint_count as number) || 0,
    pendingCaptureCount: (raw.pending_capture_count as number) || 0,
  };
}

function mapEndpoint(raw: Record<string, unknown>): LiveEndpointRow {
  return {
    id: raw.id as number,
    platformId: raw.platform_id as string,
    role: raw.role as string,
    matchType: raw.match_type as string,
    value: raw.value as string,
    confidence: raw.confidence as string,
    source: raw.source as string,
    status: raw.status as string,
    region: (raw.region as string | null) ?? null,
    lastVerifiedAt: (raw.last_verified_at as string | null) ?? null,
    createdAt: (raw.created_at as string | null) ?? null,
  };
}

function mapCandidate(raw: Record<string, unknown>): LiveCaptureCandidateRow {
  return {
    id: raw.id as number,
    platformId: raw.platform_id as string,
    role: raw.role as string,
    matchType: raw.match_type as string,
    value: raw.value as string,
    confidence: raw.confidence as string,
    source: raw.source as string,
    status: raw.status as string,
    notes: (raw.notes as string | null) ?? null,
    lineId: (raw.line_id as number | null) ?? null,
    evidence: (raw.evidence as Record<string, unknown>) || {},
    reviewedBy: (raw.reviewed_by as string | null) ?? null,
    reviewedAt: (raw.reviewed_at as string | null) ?? null,
    endpointId: (raw.endpoint_id as number | null) ?? null,
    createdAt: (raw.created_at as string | null) ?? null,
  };
}

const statusColor: Record<string, string> = {
  active: "green",
  draft: "gold",
  retired: "default",
  pending: "processing",
  approved: "green",
  rejected: "red",
};

export function LiveCatalogPage() {
  const writable = canWrite(getUser());
  const [platforms, setPlatforms] = useState<LivePlatformRow[]>([]);
  const [endpoints, setEndpoints] = useState<LiveEndpointRow[]>([]);
  const [candidates, setCandidates] = useState<LiveCaptureCandidateRow[]>([]);
  const [platformFilter, setPlatformFilter] = useState<string | undefined>();
  const [endpointOpen, setEndpointOpen] = useState(false);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [endpointForm] = Form.useForm();
  const [captureForm] = Form.useForm();

  const load = async () => {
    const [p, e, c] = await Promise.all([
      apiGet<Record<string, unknown>[]>("/admin/live-platforms"),
      apiGet<Record<string, unknown>[]>(
        `/admin/live-endpoints${platformFilter ? `?platform_id=${platformFilter}` : ""}`
      ),
      apiGet<Record<string, unknown>[]>("/admin/live-capture-candidates?status=pending"),
    ]);
    setPlatforms(p.map(mapPlatform));
    setEndpoints(e.map(mapEndpoint));
    setCandidates(c.map(mapCandidate));
  };

  useEffect(() => {
    void load().catch((e) => message.error(String(e)));
  }, [platformFilter]);

  const platformName = useMemo(() => {
    const m = new Map(platforms.map((p) => [p.id, p.displayName]));
    return (id: string) => m.get(id) || id;
  }, [platforms]);

  const submitEndpoint = async () => {
    const v = await endpointForm.validateFields();
    try {
      await apiPost("/admin/live-endpoints", {
        platform_id: v.platformId,
        role: v.role,
        match_type: v.matchType,
        value: v.value,
        confidence: v.confidence,
        source: "manual",
        status: v.status,
        region: v.region || null,
      });
      message.success("Endpoint 已创建");
      setEndpointOpen(false);
      endpointForm.resetFields();
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const submitCapture = async () => {
    const v = await captureForm.validateFields();
    try {
      await apiPost("/admin/live-capture-candidates", {
        platform_id: v.platformId,
        role: v.role,
        match_type: v.matchType,
        value: v.value,
        confidence: v.confidence,
        notes: v.notes || null,
        line_id: v.lineId ? Number(v.lineId) : null,
        evidence: v.evidence ? { note: v.evidence } : {},
      });
      message.success("抓包候选已提交，等待审核");
      setCaptureOpen(false);
      captureForm.resetFields();
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const setEndpointStatus = async (id: number, status: string) => {
    try {
      await apiPatch(`/admin/live-endpoints/${id}`, { status });
      message.success(status === "active" ? "已激活" : "已更新");
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const reviewCandidate = async (id: number, action: "approve" | "reject") => {
    try {
      await apiPost(`/admin/live-capture-candidates/${id}/${action}`, {
        activate: action === "approve",
      });
      message.success(action === "approve" ? "已通过并激活" : "已拒绝");
      await load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const platformColumns = [
    { title: "ID", dataIndex: "id", width: 140 },
    { title: "名称", dataIndex: "displayName" },
    {
      title: "强度",
      dataIndex: "liveStrength",
      render: (v: string) => <Tag>{v}</Tag>,
    },
    {
      title: "市场",
      dataIndex: "markets",
      render: (m: string[]) => m.join(", ") || "-",
    },
    {
      title: "Active",
      dataIndex: "activeEndpointCount",
      width: 80,
    },
    {
      title: "Draft",
      dataIndex: "draftEndpointCount",
      width: 80,
    },
    {
      title: "待审",
      dataIndex: "pendingCaptureCount",
      width: 80,
      render: (n: number) => (n > 0 ? <Tag color="orange">{n}</Tag> : "0"),
    },
    {
      title: "启用",
      dataIndex: "isEnabled",
      render: (v: boolean, row: LivePlatformRow) =>
        writable ? (
          <Button
            size="small"
            onClick={() =>
              void apiPatch(`/admin/live-platforms/${row.id}`, { is_enabled: !v })
                .then(() => load())
                .catch((e) => message.error(String(e)))
            }
          >
            {v ? "禁用" : "启用"}
          </Button>
        ) : (
          <Tag color={v ? "green" : "default"}>{v ? "是" : "否"}</Tag>
        ),
    },
  ];

  const endpointColumns = [
    { title: "平台", dataIndex: "platformId", render: (v: string) => platformName(v) },
    { title: "角色", dataIndex: "role", width: 90 },
    { title: "匹配", dataIndex: "matchType", width: 110 },
    { title: "值", dataIndex: "value", ellipsis: true },
    {
      title: "置信",
      dataIndex: "confidence",
      width: 80,
      render: (v: string) => <Tag>{v}</Tag>,
    },
    {
      title: "状态",
      dataIndex: "status",
      width: 90,
      render: (v: string) => <Tag color={statusColor[v]}>{v}</Tag>,
    },
    { title: "来源", dataIndex: "source", width: 100 },
    {
      title: "操作",
      width: 200,
      render: (_: unknown, row: LiveEndpointRow) =>
        writable ? (
          <Space>
            {row.status !== "active" && (
              <Button size="small" type="link" onClick={() => void setEndpointStatus(row.id, "active")}>
                激活
              </Button>
            )}
            {row.status === "active" && (
              <Button size="small" type="link" onClick={() => void setEndpointStatus(row.id, "draft")}>
                降为 draft
              </Button>
            )}
            <Button
              size="small"
              type="link"
              danger
              onClick={() =>
                Modal.confirm({
                  title: "删除 endpoint？",
                  content: row.value,
                  onOk: () =>
                    apiDelete(`/admin/live-endpoints/${row.id}`)
                      .then(() => load())
                      .catch((e) => message.error(String(e))),
                })
              }
            >
              删除
            </Button>
          </Space>
        ) : null,
    },
  ];

  const candidateColumns = [
    { title: "平台", dataIndex: "platformId", render: (v: string) => platformName(v) },
    { title: "匹配", dataIndex: "matchType", width: 110 },
    { title: "值", dataIndex: "value", ellipsis: true },
    { title: "置信", dataIndex: "confidence", width: 80 },
    { title: "线路", dataIndex: "lineId", width: 70, render: (v: number | null) => v ?? "-" },
    { title: "备注", dataIndex: "notes", ellipsis: true },
    {
      title: "提交",
      dataIndex: "createdAt",
      width: 160,
      render: (v: string | null) => (v ? formatApiTime(v) : "-"),
    },
    {
      title: "操作",
      width: 160,
      render: (_: unknown, row: LiveCaptureCandidateRow) =>
        writable ? (
          <Space>
            <Button
              size="small"
              type="primary"
              icon={<CheckOutlined />}
              onClick={() => void reviewCandidate(row.id, "approve")}
            >
              通过
            </Button>
            <Button
              size="small"
              danger
              icon={<CloseOutlined />}
              onClick={() => void reviewCandidate(row.id, "reject")}
            />
          </Space>
        ) : null,
    },
  ];

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
        <div>
          <Typography.Title level={4} style={{ margin: 0 }}>
            直播平台目录
          </Typography.Title>
          <Typography.Paragraph type="secondary" style={{ marginBottom: 0 }}>
            模式 A 路由依据：active endpoint → 节点按线 DoH 预解析 → 客户端 live_ip → Hy2。
            Draft 仅展示；抓包候选需审核后激活。
          </Typography.Paragraph>
        </div>
        {writable && (
          <Space>
            <Button icon={<PlusOutlined />} onClick={() => setCaptureOpen(true)}>
              提交抓包候选
            </Button>
            <Button type="primary" icon={<PlusOutlined />} onClick={() => setEndpointOpen(true)}>
              新增 Endpoint
            </Button>
          </Space>
        )}
      </div>

      <Tabs
        items={[
          {
            key: "platforms",
            label: "平台总览",
            children: (
              <Table
                rowKey="id"
                dataSource={platforms}
                columns={platformColumns}
                pagination={false}
                size="small"
              />
            ),
          },
          {
            key: "endpoints",
            label: `Endpoints (${endpoints.length})`,
            children: (
              <>
                <Select
                  allowClear
                  placeholder="按平台筛选"
                  style={{ width: 240, marginBottom: 12 }}
                  value={platformFilter}
                  onChange={setPlatformFilter}
                  options={platforms.map((p) => ({ value: p.id, label: p.displayName }))}
                />
                <Table
                  rowKey="id"
                  dataSource={endpoints}
                  columns={endpointColumns}
                  size="small"
                  pagination={{ pageSize: 20 }}
                />
              </>
            ),
          },
          {
            key: "capture",
            label: `抓包审核 (${candidates.length})`,
            children: (
              <Table
                rowKey="id"
                dataSource={candidates}
                columns={candidateColumns}
                size="small"
                pagination={false}
              />
            ),
          },
        ]}
      />

      <Modal title="新增 Endpoint" open={endpointOpen} onCancel={() => setEndpointOpen(false)} onOk={() => void submitEndpoint()}>
        <Form form={endpointForm} layout="vertical" initialValues={{ role: "ingest", matchType: "fqdn", confidence: "medium", status: "draft" }}>
          <Form.Item name="platformId" label="平台" rules={[{ required: true }]}>
            <Select options={platforms.map((p) => ({ value: p.id, label: p.displayName }))} />
          </Form.Item>
          <Form.Item name="role" label="角色" rules={[{ required: true }]}>
            <Select options={["ingest", "shop_api", "cdn_play", "control"].map((v) => ({ value: v, label: v }))} />
          </Form.Item>
          <Form.Item name="matchType" label="匹配类型" rules={[{ required: true }]}>
            <Select options={["fqdn", "domain_suffix", "ip_cidr"].map((v) => ({ value: v, label: v }))} />
          </Form.Item>
          <Form.Item name="value" label="值" rules={[{ required: true }]}>
            <Input placeholder="a.rtmp.youtube.com 或 .example.com" />
          </Form.Item>
          <Form.Item name="confidence" label="置信度">
            <Select options={["high", "medium", "low"].map((v) => ({ value: v, label: v }))} />
          </Form.Item>
          <Form.Item name="status" label="状态">
            <Select options={["draft", "active"].map((v) => ({ value: v, label: v }))} />
          </Form.Item>
          <Form.Item name="region" label="区域（可选）">
            <Input placeholder="sea / sg / us" />
          </Form.Item>
        </Form>
      </Modal>

      <Modal title="提交抓包候选" open={captureOpen} onCancel={() => setCaptureOpen(false)} onOk={() => void submitCapture()}>
        <Form form={captureForm} layout="vertical" initialValues={{ role: "ingest", matchType: "fqdn", confidence: "medium" }}>
          <Form.Item name="platformId" label="平台" rules={[{ required: true }]}>
            <Select options={platforms.map((p) => ({ value: p.id, label: p.displayName }))} />
          </Form.Item>
          <Form.Item name="matchType" label="匹配类型" rules={[{ required: true }]}>
            <Select options={["fqdn", "domain_suffix", "ip_cidr"].map((v) => ({ value: v, label: v }))} />
          </Form.Item>
          <Form.Item name="value" label="观测到的 ingest 主机/后缀" rules={[{ required: true }]}>
            <Input />
          </Form.Item>
          <Form.Item name="lineId" label="来源线路 ID（可选）">
            <Input placeholder="用于审计" />
          </Form.Item>
          <Form.Item name="notes" label="备注">
            <Input.TextArea rows={2} />
          </Form.Item>
          <Form.Item name="evidence" label="抓包摘要">
            <Input.TextArea rows={2} placeholder="PCAP 摘要、TLS SNI、观测时段等" />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
