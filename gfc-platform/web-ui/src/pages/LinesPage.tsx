import {
  Button,
  Form,
  Input,
  InputNumber,
  Modal,
  Select,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
  message,
  Popconfirm,
} from "antd";
import { PlusOutlined, EyeOutlined, DeleteOutlined } from "@ant-design/icons";
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import dayjs from "dayjs";
import { apiDelete, apiGet, apiPatch, apiPost } from "../api/client";
import {
  mapLineItem,
  mapNode,
  nodeOptionLabel,
  type LineListItem,
  type NodeRow,
  type SocksProfile,
} from "../types";
import { mapSocks } from "../types";
import { SocksProfileSelect } from "../components/SocksProfileSelect";

export function LinesPage() {
  const nav = useNavigate();
  const [items, setItems] = useState<LineListItem[]>([]);
  const [total, setTotal] = useState(0);
  const [nodes, setNodes] = useState<NodeRow[]>([]);
  const [socks, setSocks] = useState<SocksProfile[]>([]);
  const [countries, setCountries] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [modalOpen, setModalOpen] = useState(false);
  const [form] = Form.useForm();

  const [filters, setFilters] = useState({
    nodeId: undefined as number | undefined,
    country: undefined as string | undefined,
    status: undefined as string | undefined,
    bandwidthMbps: undefined as number | undefined,
    search: "",
    page: 1,
    pageSize: 50,
  });

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const q = new URLSearchParams();
      if (filters.nodeId) q.set("node_id", String(filters.nodeId));
      if (filters.country) q.set("country", filters.country);
      if (filters.status) q.set("status", filters.status);
      if (filters.bandwidthMbps) q.set("bandwidth_mbps", String(filters.bandwidthMbps));
      if (filters.search) q.set("search", filters.search);
      q.set("page", String(filters.page));
      q.set("page_size", String(filters.pageSize));

      const res = await apiGet<{ total: number; items: Record<string, unknown>[] }>(
        `/admin/lines?${q}`
      );
      setTotal(res.total);
      setItems(res.items.map(mapLineItem));
      const rawNodes = await apiGet<Record<string, unknown>[]>("/admin/nodes");
      setNodes(rawNodes.map(mapNode));
      const s = await apiGet<Record<string, unknown>[]>("/admin/socks");
      setSocks(s.map(mapSocks));
      setCountries(await apiGet<string[]>("/admin/meta/countries"));
    } catch (e) {
      message.error(String(e));
    } finally {
      setLoading(false);
    }
  }, [filters]);

  useEffect(() => {
    void load();
  }, [load]);

  const onCreate = async () => {
    const v = await form.validateFields();
    try {
      await apiPost("/admin/lines", {
        name: v.name,
        line_type: v.lineType || "client",
        source_cidrs: v.sourceCidrs
          ? (v.sourceCidrs as string).split(",").map((s) => s.trim()).filter(Boolean)
          : [],
        node_id: v.nodeId,
        socks_profile_id: v.socksProfileId ?? null,
        country: v.country,
        bandwidth_mbps: v.bandwidthMbps,
        remark: v.remark,
        socks_remark: v.socksRemark,
        created_by: localStorage.getItem("gfc_user") || "admin",
      });
      message.success("线路已创建");
      setModalOpen(false);
      form.resetFields();
      void load();
    } catch (e) {
      message.error(String(e));
    }
  };

  return (
    <div>
      <div className="gfc-content-header" style={{ display: "flex", justifyContent: "space-between" }}>
        <Typography.Title level={4} style={{ margin: 0 }}>
          线路管理
        </Typography.Title>
        <Button
          type="primary"
          icon={<PlusOutlined />}
          onClick={() => {
            setModalOpen(true);
            void load();
          }}
        >
          添加线路
        </Button>
      </div>

      <div className="gfc-filter-bar">
        <Space wrap>
          <Select
            placeholder="节点"
            allowClear
            style={{ width: 160 }}
            options={[
              { label: "全部节点", value: undefined },
              ...nodes.map((n) => ({ label: nodeOptionLabel(n), value: n.id })),
            ]}
            value={filters.nodeId}
            onChange={(v) => setFilters((f) => ({ ...f, nodeId: v, page: 1 }))}
          />
          <Select
            placeholder="国家/地区"
            allowClear
            style={{ width: 140 }}
            options={[{ label: "全部国家", value: undefined }, ...countries.map((c) => ({ label: c, value: c }))]}
            value={filters.country}
            onChange={(v) => setFilters((f) => ({ ...f, country: v, page: 1 }))}
          />
          <Select
            placeholder="状态"
            allowClear
            style={{ width: 120 }}
            options={[
              { label: "激活", value: "active" },
              { label: "停用", value: "inactive" },
            ]}
            value={filters.status}
            onChange={(v) => setFilters((f) => ({ ...f, status: v, page: 1 }))}
          />
          <Select
            placeholder="带宽等级"
            allowClear
            style={{ width: 120 }}
            options={[5, 10, 20, 50, 100].map((m) => ({ label: `${m}Mbps`, value: m }))}
            value={filters.bandwidthMbps}
            onChange={(v) => setFilters((f) => ({ ...f, bandwidthMbps: v, page: 1 }))}
          />
          <Input.Search
            placeholder="TID / 备注"
            allowClear
            style={{ width: 220 }}
            onSearch={(v) => setFilters((f) => ({ ...f, search: v, page: 1 }))}
          />
          <Button type="primary" onClick={() => void load()}>
            筛选
          </Button>
        </Space>
        <div style={{ marginTop: 12, color: "#64748b", fontSize: 13 }}>
          共 {total} 条记录 | 客户端 Agent 轮询约 10 秒
        </div>
      </div>

      <Table
        rowKey="id"
        loading={loading}
        dataSource={items}
        pagination={{
          current: filters.page,
          pageSize: filters.pageSize,
          total,
          showSizeChanger: true,
          pageSizeOptions: ["20", "50", "100"],
          onChange: (page, pageSize) => setFilters((f) => ({ ...f, page, pageSize })),
        }}
        columns={[
          {
            title: "TID",
            dataIndex: "tid",
            render: (tid: string, r) => <Link to={`/lines/${r.id}`}>{tid}</Link>,
          },
          { title: "节点", dataIndex: "nodeName" },
          { title: "国家", dataIndex: "country" },
          {
            title: "带宽",
            dataIndex: "bandwidthMbps",
            render: (v: number) => <Tag color="purple">{v}Mbps</Tag>,
          },
          {
            title: "客户端",
            dataIndex: "clientDeviceName",
            render: (name: string | null, r) =>
              r.clientDeviceId ? (
                <Link to={`/client-devices/${r.clientDeviceId}`}>{name || `#${r.clientDeviceId}`}</Link>
              ) : (
                <Typography.Text type="secondary">未绑定</Typography.Text>
              ),
          },
          { title: "备注", dataIndex: "remark", ellipsis: true },
          {
            title: "活跃",
            dataIndex: "isEnabled",
            render: (v: boolean, r) => (
              <Switch
                checked={v}
                size="small"
                onChange={async (checked) => {
                  await apiPatch(`/admin/lines/${r.id}`, { is_enabled: checked });
                  void load();
                }}
              />
            ),
          },
          {
            title: "状态",
            dataIndex: "status",
            render: (s: string) => (
              <Tag color={s === "active" ? "green" : "default"}>{s === "active" ? "激活" : "停用"}</Tag>
            ),
          },
          {
            title: "创建时间",
            dataIndex: "createdAt",
            render: (v: string) => dayjs(v).format("YYYY-MM-DD HH:mm:ss"),
          },
          {
            title: "操作",
            render: (_, r) => (
              <Space>
                <Button type="link" icon={<EyeOutlined />} onClick={() => nav(`/lines/${r.id}`)} />
                <Popconfirm
                  title="确认删除该线路？"
                  onConfirm={async () => {
                    await apiDelete(`/admin/lines/${r.id}`);
                    message.success("已删除");
                    void load();
                  }}
                >
                  <Button type="link" danger icon={<DeleteOutlined />} />
                </Popconfirm>
              </Space>
            ),
          },
        ]}
      />

      <Modal
        title="添加线路"
        open={modalOpen}
        onOk={() => void onCreate()}
        onCancel={() => setModalOpen(false)}
        width={560}
        destroyOnClose
      >
        <Form
          form={form}
          layout="vertical"
          initialValues={{ bandwidthMbps: 5, country: "", lineType: "client" }}
        >
          <Form.Item name="lineType" label="线路类型" rules={[{ required: true }]}>
            <Select
              options={[
                { label: "客户端线路 (VLESS+REALITY)", value: "client" },
                { label: "转发线路 (VyOS 源 IP)", value: "forward" },
              ]}
            />
          </Form.Item>
          <Form.Item name="name" label="线路名称（可选，留空自动生成 TID）">
            <Input placeholder="客户业务名" />
          </Form.Item>
          <Form.Item noStyle shouldUpdate={(p, c) => p.lineType !== c.lineType}>
            {({ getFieldValue }) =>
              getFieldValue("lineType") === "forward" ? (
                <Form.Item name="sourceCidrs" label="源 IP 段（逗号分隔）" rules={[{ required: true }]}>
                  <Input placeholder="10.1.0.0/24,10.1.1.0/24" />
                </Form.Item>
              ) : null
            }
          </Form.Item>
          <Form.Item name="nodeId" label="绑定节点" rules={[{ required: true }]}>
            <Select options={nodes.map((n) => ({ label: nodeOptionLabel(n), value: n.id }))} />
          </Form.Item>
          <Form.Item name="socksProfileId" label="绑定 SOCKS（留空则走节点本地出口）">
            <SocksProfileSelect profiles={socks} />
          </Form.Item>
          <Form.Item name="country" label="国家/地区">
            <Input placeholder="马来西亚" />
          </Form.Item>
          <Form.Item name="bandwidthMbps" label="带宽 (Mbps)">
            <InputNumber min={1} max={1000} style={{ width: "100%" }} />
          </Form.Item>
          <Form.Item name="remark" label="备注">
            <Input.TextArea rows={2} />
          </Form.Item>
          <Form.Item name="socksRemark" label="Socks5 配置备注">
            <Input />
          </Form.Item>
        </Form>
      </Modal>
    </div>
  );
}
