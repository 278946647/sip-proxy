import {
  Alert,
  Button,
  Input,
  Select,
  Space,
  Table,
  Tabs,
  Tag,
  Typography,
  message,
} from "antd";
import { DeleteOutlined, EyeOutlined, ReloadOutlined } from "@ant-design/icons";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import dayjs from "dayjs";
import relativeTime from "dayjs/plugin/relativeTime";
import { apiDelete, apiGet, apiPatch } from "../api/client";
import { openRemoteTarget } from "../lib/openRemote";
import { confirmDeleteClientDevice } from "../utils/dangerousConfirm";
import { mapClientDevice, type ClientDeviceListItem, type LineListItem } from "../types";
import { mapLineItem } from "../types";
import { getUser } from "../api/auth";
import { isOperatorDeletableClient, permissionsFromUser } from "../utils/permissions";

dayjs.extend(relativeTime);

type RowDraft = {
  name: string;
  lineId: number | undefined;
};

type DeviceTab = "attention" | "active" | "suspended" | "all";

const SERVICE_REASON_LABEL: Record<string, string> = {
  line_disabled: "线路已禁用",
  line_deleted: "线路已删除",
  line_unbound: "未绑线",
  node_offline: "节点离线",
  agent_not_active: "Agent 未就绪",
};

function managementTag(state: ClientDeviceListItem["managementState"]) {
  return state === "online" ? (
    <Tag color="green">在线</Tag>
  ) : (
    <Tag color="red">离线</Tag>
  );
}

function serviceTag(item: ClientDeviceListItem) {
  const map: Record<ClientDeviceListItem["serviceState"], { color: string; label: string }> = {
    active: { color: "green", label: "业务正常" },
    suspended: { color: "orange", label: "业务关停" },
    unbound: { color: "default", label: "未绑线" },
    degraded: { color: "volcano", label: "业务异常" },
    unknown: { color: "default", label: "—" },
  };
  const meta = map[item.serviceState] ?? map.unknown;
  return <Tag color={meta.color}>{meta.label}</Tag>;
}

function matchesTab(item: ClientDeviceListItem, tab: DeviceTab) {
  if (tab === "all") return true;
  if (tab === "attention") {
    return item.managementState === "offline" || item.serviceState === "degraded";
  }
  if (tab === "active") {
    return item.managementState === "online" && item.serviceState === "active";
  }
  if (tab === "suspended") {
    return (
      item.managementState === "online" &&
      (item.serviceState === "suspended" || item.serviceState === "unbound")
    );
  }
  return true;
}

export function ClientDevicesPage() {
  const nav = useNavigate();
  const [items, setItems] = useState<ClientDeviceListItem[]>([]);
  const [lines, setLines] = useState<LineListItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [drafts, setDrafts] = useState<Record<number, RowDraft>>({});
  const [lastRefresh, setLastRefresh] = useState(dayjs());
  const [activeTab, setActiveTab] = useState<DeviceTab>("all");
  const perms = permissionsFromUser(getUser());

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

  const counts = useMemo(() => {
    const attention = items.filter((i) => matchesTab(i, "attention")).length;
    const active = items.filter((i) => matchesTab(i, "active")).length;
    const suspended = items.filter((i) => matchesTab(i, "suspended")).length;
    return { attention, active, suspended, all: items.length };
  }, [items]);

  const visibleItems = useMemo(
    () => items.filter((item) => matchesTab(item, activeTab)),
    [items, activeTab]
  );

  const getDraft = (row: ClientDeviceListItem): RowDraft =>
    drafts[row.id] ?? {
      name: row.name,
      lineId: row.lineId ?? undefined,
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
        `/admin/client-devices/${row.id}?operator=${localStorage.getItem("gfc_user") || "admin"}&confirm=true`
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
        }
      );
      message.success("已保存，客户端将在下次拉取配置后生效");
      void load();
    } catch (e) {
      message.error(String(e));
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
        message="已纳管设备可在本页直接更换关联线路（无需重刷码）。解绑线路将切换为直连模式但保持在线管控。刷码适用于首次激活或本地状态恢复。"
      />

      <div style={{ marginBottom: 12, color: "#64748b", fontSize: 13 }}>
        上次刷新：{lastRefresh.format("HH:mm:ss")} | 共 {items.length} 台设备
      </div>

      <Tabs
        className="client-device-tabs"
        activeKey={activeTab}
        onChange={(key) => setActiveTab(key as DeviceTab)}
        items={[
          { key: "all", label: `全部 (${counts.all})` },
          { key: "attention", label: `需关注 (${counts.attention})` },
          { key: "active", label: `在线 · 业务正常 (${counts.active})` },
          { key: "suspended", label: `在线 · 业务关停 (${counts.suspended})` },
        ]}
      />

      <Table
        rowKey="id"
        loading={loading}
        dataSource={visibleItems}
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
            title: "管控状态",
            render: (_, row) => managementTag(row.managementState),
          },
          {
            title: "业务状态",
            render: (_, row) => (
              <Space direction="vertical" size={2}>
                {serviceTag(row)}
                {row.serviceReason ? (
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {SERVICE_REASON_LABEL[row.serviceReason] ?? row.serviceReason}
                  </Typography.Text>
                ) : null}
              </Space>
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
            title: "最后在线",
            dataIndex: "lastSeenAt",
            render: (v: string | null) =>
              v ? (
                <Space direction="vertical" size={0}>
                  <span>{dayjs(v).format("MM-DD HH:mm:ss")}</span>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {dayjs(v).fromNow()}
                  </Typography.Text>
                </Space>
              ) : (
                "-"
              ),
          },
          {
            title: "反代端口",
            render: (_, row) => (
              <Space direction="vertical" size={0}>
                <Typography.Text code>SSH {row.reverseSshPort ?? "-"}</Typography.Text>
                <Typography.Text code type="secondary">
                  HTTP {row.reverseHttpPort ?? "-"}
                </Typography.Text>
                {!row.sshPublicKeyRegistered ? (
                  <Typography.Text type="warning" style={{ fontSize: 12 }}>
                    公钥未注册
                  </Typography.Text>
                ) : null}
              </Space>
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
                options={lines
                  .filter((l) => l.lineType === "client")
                  .map((l) => ({
                    label: `${l.tid}${!l.isEnabled ? " (已禁用)" : ""}${
                      l.clientDeviceId && l.clientDeviceId !== row.id ? " (已占用)" : ""
                    }`,
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
                {perms.actions.includes("write_safe") && (
                <Button size="small" type="primary" onClick={() => void saveRow(row)}>
                  保存
                </Button>
                )}
                {perms.canRemoteAccess && (
                <>
                <Button
                  size="small"
                  type="primary"
                  ghost
                  disabled={!row.online || !row.sshPublicKeyRegistered || !row.reverseSshPort}
                  onClick={() => void openRemoteTarget(row.id, "ssh", row.name)}
                >
                  远程 SSH
                </Button>
                <Button
                  size="small"
                  disabled={!row.online || !row.sshPublicKeyRegistered || !row.reverseSshPort}
                  onClick={() => void openRemoteTarget(row.id, "web", row.name)}
                >
                  Web 管理
                </Button>
                <Button
                  size="small"
                  disabled={!row.online || !row.sshPublicKeyRegistered || !row.reverseSshPort}
                  onClick={() => void openRemoteTarget(row.id, "flash", row.name)}
                >
                  刷码协助
                </Button>
                </>
                )}
                <Button
                  size="small"
                  icon={<EyeOutlined />}
                  onClick={() => nav(`/client-devices/${row.id}`)}
                />
                {(perms.canDeleteStructural || isOperatorDeletableClient(row)) && (
                <Button
                  size="small"
                  danger
                  icon={<DeleteOutlined />}
                  onClick={() =>
                    confirmDeleteClientDevice(row.name, () => deleteRow(row))
                  }
                >
                  删除
                </Button>
                )}
              </Space>
            ),
          },
        ]}
      />

      <div style={{ marginTop: 8 }}>
        尚无设备？请在线路详情页复制 <Link to="/lines">线路码</Link> 刷入客户端盒子。
      </div>
    </div>
  );
}
