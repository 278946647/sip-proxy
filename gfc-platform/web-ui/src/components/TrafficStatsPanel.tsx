import { Typography } from "antd";
import { LineChartOutlined } from "@ant-design/icons";
import type { FlowStat } from "../types";
import { TrafficChart, formatBytes } from "./TrafficChart";

type Props = {
  stats: FlowStat[];
  updatedAt: string;
};

function formatTrafficTotal(stats: FlowStat[]) {
  const total = stats.reduce((sum, s) => sum + s.bytesIn + s.bytesOut, 0);
  return formatBytes(total);
}

function lastSampleTotal(stats: FlowStat[]) {
  if (stats.length === 0) return "0 B";
  const last = stats[stats.length - 1];
  return formatBytes(last.bytesIn + last.bytesOut);
}

export function TrafficStatsPanel({ stats, updatedAt }: Props) {
  return (
    <div className="traffic-stats-panel">
      <div className="traffic-stats-summary">
        <div className="traffic-stats-title">
          <LineChartOutlined />
          <span>流量统计（最近 24 小时）</span>
        </div>
        <div className="traffic-stats-metrics">
          <span>
            <strong>24h 总流量:</strong> {formatTrafficTotal(stats)}
          </span>
          <span>
            <strong>最近一次:</strong> {lastSampleTotal(stats)}
          </span>
          <Typography.Text type="secondary">更新于 {updatedAt}</Typography.Text>
        </div>
      </div>
      <TrafficChart stats={stats} height={120} />
    </div>
  );
}
