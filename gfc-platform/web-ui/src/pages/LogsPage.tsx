import { Card, Table, Typography, message } from "antd";
import { useEffect, useState } from "react";
import dayjs from "dayjs";
import { apiGet } from "../api/client";
import type { OperationLog } from "../types";

export function LogsPage() {
  const [logs, setLogs] = useState<OperationLog[]>([]);

  useEffect(() => {
    void apiGet<Record<string, unknown>[]>("/admin/operation-logs")
      .then((rows) =>
        setLogs(
          rows.map((x) => ({
            id: x.id as number,
            username: x.username as string,
            action: x.action as string,
            target: x.target as string,
            detail: x.detail as string | null,
            createdAt: x.created_at as string,
          }))
        )
      )
      .catch((e) => message.error(String(e)));
  }, []);

  return (
    <div>
      <Typography.Title level={4}>操作日志</Typography.Title>
      <Card>
        <Table
          rowKey="id"
          dataSource={logs}
          columns={[
            {
              title: "时间",
              dataIndex: "createdAt",
              width: 180,
              render: (v) => dayjs(v).format("YYYY-MM-DD HH:mm:ss"),
            },
            { title: "用户", dataIndex: "username", width: 100 },
            { title: "操作", dataIndex: "action", width: 120 },
            { title: "对象", dataIndex: "target", width: 160 },
            { title: "详情", dataIndex: "detail", ellipsis: true },
          ]}
        />
      </Card>
    </div>
  );
}
