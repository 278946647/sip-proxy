import {
  Alert,
  Button,
  Dropdown,
  Space,
  Table,
  Tabs,
  Tag,
  Typography,
  message,
} from "antd";
import type { MenuProps } from "antd";
import { DeleteOutlined, DownOutlined, EyeOutlined, ReloadOutlined } from "@ant-design/icons";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { apiDelete, apiGet } from "../api/client";
import { formatApiTime, formatApiTimeFromNow, nowDisplay } from "../utils/datetime";
import { openRemoteTarget } from "../lib/openRemote";
import { confirmDeleteClientDevice } from "../utils/dangerousConfirm";
import {
  lineBindingLabel,
  mapClientDevice,
  mapLineItem,
  type ClientDeviceListItem,
  type LineListItem,
} from "../types";
import { getUser } from "../api/auth";
import { isOperatorDeletableClient, permissionsFromUser } from "../utils/permissions";

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

function resolveLine(row: ClientDeviceListItem, lines: LineListItem[]): LineListItem | null {
  if (!row.lineId) return null;
  return lines.find((l) => l.id === row.lineId) ?? null;
}

function LineSummary({
  row,
  lines,
}: {
  row: ClientDeviceListItem;
  lines: LineListItem[];
}) {
  if (!row.lineId) {
    return <Tag>未绑线</Tag>;
  }
  const line = resolveLine(row, lines);
  if (!line) {
    return <Tag color="orange">线路已删除</Tag>;
  }
  const label = lineBindingLabel(line.tid, line.nodeName, line.country);
  return (
    <Space direction="vertical" size={2}>
      <Link to={`/lines/${line.id}`}>{label}</Link>
      {!line.isEnabled ? (
        <Typography.Text type="warning" style={{ fontSize: 12 }}>
          线路已禁用
        </Typography.Text>
      ) : null}
    </Space>
  );
}

export function ClientDevicesPage() {
  const nav = useNavigate();
  const [items, setItems] = useState<ClientDeviceListItem[]>([]);
  const [lines, setLines] = useState<LineListItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [lastRefresh, setLastRefresh] = useState(nowDisplay());
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
      setLastRefresh(nowDisplay());
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

  const remoteReady = (row: ClientDeviceListItem) =>
    row.managementState === "online" && row.sshPublicKeyRegistered && !!row.reverseSshPort;

  const remoteMenu = (row: ClientDeviceListItem): MenuProps => ({
    items: [
      {
        key: "ssh",
        label: "远程 SSH",
        disabled: !remoteReady(row),
        onClick: () => void openRemoteTarget(row.id, "ssh", row.name),
      },
      {
        key: "web",
        label: "Web 管理",
        disabled: !remoteReady(row),
        onClick: () => void openRemoteTarget(row.id, "web", row.name),
      },
      {
        key: "flash",
        label: "刷码协助",
        disabled: !remoteReady(row),
        onClick: () => void openRemoteTarget(row.id, "flash", row.name),
      },
    ],
  });

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
        message="列表展示设备管控与业务状态。更换线路、编辑名称等操作请进入设备详情。刷码适用于首次激活或本地状态恢复。"
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
        locale={{
          emptyText: (
            <>
              暂无设备，请在线路详情页复制{" "}
              <Link to="/lines">线路码</Link> 刷入客户端盒子。
            </>
          ),
        }}
        columns={[
          {
            title: "设备名称",
            render: (_, row) => (
              <Link to={`/client-devices/${row.id}`}>
                <Typography.Text strong>{row.name}</Typography.Text>
              </Link>
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
            title: "关联线路",
            render: (_, row) => <LineSummary row={row} lines={lines} />,
          },
          {
            title: "最后在线",
            dataIndex: "lastSeenAt",
            render: (v: string | null) =>
              v ? (
                <Space direction="vertical" size={0}>
                  <span>{formatApiTime(v, "MM-DD HH:mm:ss")}</span>
                  <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                    {formatApiTimeFromNow(v)}
                  </Typography.Text>
                </Space>
              ) : (
                "-"
              ),
          },
          {
            title: "操作",
            render: (_, row) => (
              <Space wrap>
                <Button
                  size="small"
                  icon={<EyeOutlined />}
                  onClick={() => nav(`/client-devices/${row.id}`)}
                >
                  详情
                </Button>
                {perms.canRemoteAccess && (
                  <Dropdown menu={remoteMenu(row)} disabled={!remoteReady(row)}>
                    <Button size="small">
                      远程 <DownOutlined />
                    </Button>
                  </Dropdown>
                )}
                {(perms.canDeleteStructural || isOperatorDeletableClient(row)) && (
                  <Button
                    size="small"
                    danger
                    icon={<DeleteOutlined />}
                    onClick={() => confirmDeleteClientDevice(row.name, () => deleteRow(row))}
                  >
                    删除
                  </Button>
                )}
              </Space>
            ),
          },
        ]}
      />
    </div>
  );
}
