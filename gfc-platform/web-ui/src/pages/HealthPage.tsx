import { Button, Card, Popconfirm, Table, Tag, Typography, message } from "antd";
import { useEffect, useState } from "react";
import dayjs from "dayjs";
import { apiDelete, apiGet } from "../api/client";
import type { AlertEvent, NodeRow } from "../types";

export function HealthPage() {
  const [nodes, setNodes] = useState<NodeRow[]>([]);
  const [alerts, setAlerts] = useState<AlertEvent[]>([]);

  useEffect(() => {
    const load = async () => {
      try {
        setNodes(await apiGet<NodeRow[]>("/admin/nodes"));
        const a = await apiGet<Record<string, unknown>[]>("/admin/alerts?limit=100&active_only=true");
        setAlerts(
          a.map((x) => ({
            id: x.id as number,
            nodeId: x.node_id as number | null,
            lineId: x.line_id as number | null,
            level: x.level as string,
            type: x.type as string,
            message: x.message as string,
            createdAt: x.created_at as string,
          }))
        );
      } catch (e) {
        message.error(String(e));
      }
    };
    void load();
    const t = setInterval(() => void load(), 5000);
    return () => clearInterval(t);
  }, []);

  return (
    <div>
      <Typography.Title level={4}>健康检查</Typography.Title>
      <Card title="节点探活（2 分钟内有心跳视为在线）" style={{ marginBottom: 16 }}>
        <Table
          rowKey="id"
          dataSource={nodes}
          columns={[
            { title: "节点", dataIndex: "name" },
            { title: "Region", dataIndex: "region" },
            {
              title: "状态",
              render: (_, r) =>
                r.online ? <Tag color="green">在线</Tag> : <Tag color="red">离线</Tag>,
            },
            { title: "公网 IP", dataIndex: "publicIp", render: (v) => v || "-" },
            { title: "最近心跳", dataIndex: "lastSeenAt" },
            {
              title: "配置版本",
              dataIndex: "currentConfigVersion",
              ellipsis: true,
              render: (v) => v || "-",
            },
          ]}
        />
      </Card>
      <Card
        title="当前告警"
        extra={
          <Popconfirm
            title="清空全部历史告警？"
            description="仅删除数据库中的告警记录，不影响当前监控"
            onConfirm={async () => {
              try {
                const res = await apiDelete<{ deleted: number }>("/admin/alerts");
                message.success(`已清理 ${res.deleted} 条告警`);
                const a = await apiGet<Record<string, unknown>[]>("/admin/alerts?limit=100&active_only=true");
                setAlerts(
                  a.map((x) => ({
                    id: x.id as number,
                    nodeId: x.node_id as number | null,
                    lineId: x.line_id as number | null,
                    level: x.level as string,
                    type: x.type as string,
                    message: x.message as string,
                    createdAt: x.created_at as string,
                  }))
                );
              } catch (e) {
                message.error(String(e));
              }
            }}
          >
            <Button danger size="small">
              清空历史告警
            </Button>
          </Popconfirm>
        }
      >
        <Table
          rowKey="id"
          dataSource={alerts}
          columns={[
            {
              title: "级别",
              dataIndex: "level",
              render: (v: string) => (
                <Tag color={v === "critical" ? "red" : v === "warn" ? "orange" : "blue"}>{v}</Tag>
              ),
            },
            { title: "类型", dataIndex: "type" },
            { title: "节点 ID", dataIndex: "nodeId", render: (v) => v ?? "-" },
            { title: "消息", dataIndex: "message", ellipsis: true },
            {
              title: "时间",
              dataIndex: "createdAt",
              render: (v) => dayjs(v).format("YYYY-MM-DD HH:mm:ss"),
            },
          ]}
        />
      </Card>
    </div>
  );
}
