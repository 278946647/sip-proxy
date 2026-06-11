import { Card, Empty, Table, Typography, message } from "antd";
import { useEffect, useState } from "react";
import dayjs from "dayjs";
import { apiGet } from "../api/client";
import type { FlowStat } from "../types";

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export function TrafficPage() {
  const [stats, setStats] = useState<FlowStat[]>([]);

  useEffect(() => {
    void apiGet<Record<string, unknown>[]>("/admin/flow-stats")
      .then((rows) =>
        setStats(
          rows.map((x) => ({
            id: x.id as number,
            nodeId: x.node_id as number,
            lineId: x.line_id as number | null,
            windowStart: x.window_start as string,
            windowSeconds: x.window_seconds as number,
            bytesIn: x.bytes_in as number,
            bytesOut: x.bytes_out as number,
            activeConns: x.active_conns as number,
          }))
        )
      )
      .catch((e) => message.error(String(e)));
  }, []);

  return (
    <div>
      <Typography.Title level={4}>流量统计</Typography.Title>
      <Card>
        {stats.length === 0 ? (
          <Empty description="暂无流量数据。节点 Agent 上报后将在此展示（按线路/时间窗聚合）。" />
        ) : (
          <Table
            rowKey="id"
            dataSource={stats}
            columns={[
              { title: "节点 ID", dataIndex: "nodeId" },
              { title: "线路 ID", dataIndex: "lineId", render: (v) => v ?? "-" },
              {
                title: "窗口",
                dataIndex: "windowStart",
                render: (v, r) =>
                  `${dayjs(v).format("MM-DD HH:mm")} (${r.windowSeconds}s)`,
              },
              { title: "入站", dataIndex: "bytesIn", render: formatBytes },
              { title: "出站", dataIndex: "bytesOut", render: formatBytes },
              { title: "活跃连接", dataIndex: "activeConns" },
            ]}
          />
        )}
      </Card>
    </div>
  );
}
