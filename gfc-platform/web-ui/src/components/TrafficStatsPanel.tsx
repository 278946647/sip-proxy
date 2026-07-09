import { Typography } from "antd";
import { LineChartOutlined } from "@ant-design/icons";
import type { FlowStat } from "../types";
import { TrafficChart, flowRateMBps, formatBytes, formatRateMBps } from "./TrafficChart";

type Props = {
  stats: FlowStat[];
  updatedAt: string;
};

function formatTrafficTotal(stats: FlowStat[]) {
  const total = stats.reduce((sum, s) => sum + s.bytesIn + s.bytesOut, 0);
  return formatBytes(total);
}

function peakRateMBps(stats: FlowStat[]) {
  if (stats.length === 0) return 0;
  return Math.max(...stats.map((s) => flowRateMBps(s.bytesIn, s.bytesOut, s.windowSeconds)));
}

function lastRateMBps(stats: FlowStat[]) {
  if (stats.length === 0) return 0;
  const last = stats[stats.length - 1];
  return flowRateMBps(last.bytesIn, last.bytesOut, last.windowSeconds);
}

export function TrafficStatsPanel({ stats, updatedAt }: Props) {
  return (
    <div className="traffic-stats-panel">
      <div className="traffic-stats-summary">
        <div className="traffic-stats-title">
          <LineChartOutlined />
          <span>gfctun 代理流量（最近 24 小时）</span>
        </div>
        <div className="traffic-stats-metrics">
          <span>
            <strong>24h 总量:</strong> {formatTrafficTotal(stats)}
          </span>
          <span>
            <strong>当前速率:</strong> {formatRateMBps(lastRateMBps(stats))}
          </span>
          <span>
            <strong>峰值速率:</strong> {formatRateMBps(peakRateMBps(stats))}
          </span>
          <Typography.Text type="secondary">更新于 {updatedAt}</Typography.Text>
        </div>
      </div>
      <Typography.Text type="secondary" className="traffic-stats-hint">
        仅统计经 gfctun 转发的国际代理流量，不含国内直连与物理口总流量；图表纵轴为 MB/s。
      </Typography.Text>
      <TrafficChart stats={stats} height={140} />
    </div>
  );
}
