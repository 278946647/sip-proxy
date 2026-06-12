import {
  Alert,
  Button,
  Input,
  InputNumber,
  Modal,
  Popconfirm,
  Select,
  Space,
  Table,
  Tag,
  Typography,
  message,
} from "antd";
import { LineCodeField } from "../components/LineCodeField";
import { DeleteOutlined, EyeOutlined, ReloadOutlined } from "@ant-design/icons";
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import dayjs from "dayjs";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { mapClientDevice, type ClientDeviceListItem, type LineListItem } from "../types";
import { mapLineItem } from "../types";

type RowDraft = {
  name: string;
  lineId: number | undefined;
  reverseSshPort: number | undefined;
};

export function ClientDevicesPage() {
  const nav = useNavigate();
  const [items, setItems] = useState<ClientDeviceListItem[]>([]);
  const [lines, setLines] = useState<LineListItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [drafts, setDrafts] = useState<Record<number, RowDraft>>({});
  const [lastRefresh, setLastRefresh] = useState(dayjs());
  const [lineCodeModal, setLineCodeModal] = useState<{ open: boolean; code: string; tid: string }>({
    open: false,
    code: "",
    tid: "",
  });
  const [codeLoading, setCodeLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await apiGet<{ total: number; items: Record<string, unknown>[] }>(
        "/admin/client-devices?page_size=200"
      );
      setItems(res.items.map(mapClientDevice));
      const lineRes = await apiGet<{ total: number; items: Record<string, unknown>[] }>(
        "/admin/lines?page_size=200"
      );
      setLines(lineRes.items.map(mapLineItem));
      setLastRefresh(dayjs());
    } catch (e) {
      message.error(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(), 15000);
    return () => window.clearInterval(timer);
  }, [load]);

  const getDraft = (row: ClientDeviceListItem): RowDraft =>
    drafts[row.id] ?? {
      name: row.name,
      lineId: row.lineId ?? undefined,
      reverseSshPort: row.reverseSshPort ?? undefined,
    };

  const setDraft = (id: number, patch: Partial<RowDraft>) => {
    setDrafts((prev) => {
      const row = items.find((i) => i.id === id);
      if (!row) return prev;
      return { ...prev, [id]: { ...getDraft(row), ...patch } };
    });
  };

  const deleteRow = async (row: ClientDeviceListItem) => {
    try {
      const res = await apiDelete<{ ok: boolean; message?: string }>(
        `/admin/client-devices/${row.id}?operator=${localStorage.getItem("gfc_user") || "admin"}`
      );
      message.success(res.message || "已删除");
      void load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const saveRow = async (row: ClientDeviceListItem) => {
    const draft = getDraft(row);
    try {
      await apiPatch(
        `/admin/client-devices/${row.id}?operator=${localStorage.getItem("gfc_user") || "admin"}`,
        {
          name: draft.name,
          line_id: draft.lineId ?? null,
          reverse_ssh_port: draft.reverseSshPort ?? null,
        }
      );
      message.success("已保存");
      void load();
    } catch (e) {
      message.error(String(e));
    }
  };

  const showLineCode = async (lineId: number | null) => {
    if (!lineId) {
      message.warning("请先关联线路");
      return;
    }
    setCodeLoading(true);
    try {
      const res = await apiGet<{ line_code_b32: string }>(`/admin/lines/${lineId}/line-code`);
      const ln = lines.find((l) => l.id === lineId);
      setLineCodeModal({
        open: true,
        code: res.line_code_b32 || "",
        tid: ln?.tid || `#${lineId}`,
      });
    } catch (e) {
      message.error(String(e));
    } finally {
      setCodeLoading(false);
    }
  };

  return (
    <div>
      <div className="gfc-content-header" style={{ display: "flex", justifyContent: "space-between" }}>
        <Typography.Title level={4} style={{ margin: 0 }}>
          客户端管理
        </Typography.Title>
        <Button icon={<ReloadOutlined />} onClick={() => void load()}>
          立即刷新状态
        </Button>
      </div>

      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message="设备通过线路码激活后出现在此列表。可删除误注册记录；在线设备会在下次心跳时凭线路码自动重新注册。反向 SSH 端口用于远程 WebSSH。"
      />

      <div style={{ marginBottom: 12, color: "#64748b", fontSize: 13 }}>
        上次刷新：{lastRefresh.format("HH:mm:ss")} | 共 {items.length} 台设备
      </div>

      <Table
        rowKey="id"
        loading={loading}
        dataSource={items}
        pagination={{ pageSize: 50 }}
        columns={[
          {
            title: "设备名称",
            render: (_, row) => (
              <Input
                value={getDraft(row).name}
                onChange={(e) => setDraft(row.id, { name: e.target.value })}
                style={{ minWidth: 160 }}
              />
            ),
          },
          {
            title: "状态",
            dataIndex: "online",
            render: (online: boolean) => (
              <Tag color={online ? "green" : "red"}>{online ? "在线" : "离线"}</Tag>
            ),
          },
          {
            title: "LAN MAC",
            dataIndex: "lanMac",
            render: (v: string | null) => (
              <Typography.Text code copyable={!!v}>
                {v || "-"}
              </Typography.Text>
            ),
          },
          {
            title: "设备 ID",
            dataIndex: "deviceId",
            render: (v: string | null) => v || "-",
          },
          {
            title: "反向端口",
            render: (_, row) => (
              <InputNumber
                min={1}
                max={65535}
                value={getDraft(row).reverseSshPort}
                onChange={(v) => setDraft(row.id, { reverseSshPort: v ?? undefined })}
                style={{ width: 100 }}
              />
            ),
          },
          {
            title: "关联线路",
            render: (_, row) => (
              <Select
                allowClear
                placeholder="---未关联---"
                style={{ minWidth: 180 }}
                value={getDraft(row).lineId}
                onChange={(v) => setDraft(row.id, { lineId: v })}
                options={lines.map((l) => ({
                  label: `${l.tid}${l.clientDeviceId && l.clientDeviceId !== row.id ? " (已占用)" : ""}`,
                  value: l.id,
                  disabled: !!l.clientDeviceId && l.clientDeviceId !== row.id,
                }))}
              />
            ),
          },
          {
            title: "操作",
            render: (_, row) => (
              <Space wrap>
                <Button size="small" type="primary" onClick={() => void saveRow(row)}>
                  保存
                </Button>
                <Button size="small" onClick={() => void showLineCode(getDraft(row).lineId ?? row.lineId)}>
                  线路码
                </Button>
                <Button
                  size="small"
                  type="primary"
                  ghost
                  disabled={!row.reverseSshPort}
                  onClick={() => {
                    if (row.reverseSshPort) {
                      window.open(`/#/client-devices/${row.id}`, "_blank");
                      message.info(`SSH 反代端口：${row.reverseSshPort}（需配置 WebSSH 网关）`);
                    }
                  }}
                >
                  SSH 连接
                </Button>
                <Button
                  size="small"
                  icon={<EyeOutlined />}
                  onClick={() => nav(`/client-devices/${row.id}`)}
                />
                <Popconfirm
                  title="删除此客户端记录？"
                  description="在线设备将自动重新注册；线路码仍有效。"
                  onConfirm={() => void deleteRow(row)}
                >
                  <Button size="small" danger icon={<DeleteOutlined />}>
                    删除
                  </Button>
                </Popconfirm>
              </Space>
            ),
          },
        ]}
      />

      <div style={{ marginTop: 8 }}>
        尚无设备？请在线路详情页复制 <Link to="/lines">线路码</Link> 刷入客户端盒子。
      </div>

      <Modal
        title={`线路码 — ${lineCodeModal.tid}`}
        open={lineCodeModal.open}
        onCancel={() => setLineCodeModal((m) => ({ ...m, open: false }))}
        footer={null}
        width={720}
        destroyOnClose
      >
        <LineCodeField value={lineCodeModal.code} loading={codeLoading} rows={5} />
      </Modal>
    </div>
  );
}
