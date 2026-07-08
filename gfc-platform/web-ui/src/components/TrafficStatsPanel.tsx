import { Button, Space, Switch, Typography } from "antd";
import { CaretRightOutlined, LineChartOutlined, PauseOutlined } from "@ant-design/icons";
import { useMemo } from "react";
import type { FlowStat } from "../types";
import { TrafficChart, formatBytes } from "./TrafficChart";

type Props = {
  stats: FlowStat[];
  enabled: boolean;
  paused: boolean;
  updatedAt: string;
  saving?: boolean;
  onToggleEnabled: (checked: boolean) => void;
  onTogglePause: () => void;
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

export function TrafficStatsPanel({
  stats,
  enabled,
  paused,
  updatedAt,
  saving,
  onToggleEnabled,
  onTogglePause,
}: Props) {
  const statusLabel = useMemo(() => {
    if (!enabled) return "disabled";
    if (paused) return "paused";
    return "active";
  }, [enabled, paused]);

  return (
    <div className="traffic-stats-panel">
      <div className="traffic-stats-toolbar">
        <Space>
          <Typography.Text>启用流量统计</Typography.Text>
          <Switch
            checked={enabled}
            loading={saving}
            checkedChildren="开"
            unCheckedChildren="关"
            onChange={onToggleEnabled}
          />
        </Space>
      </div>

      <div className="traffic-stats-header">
        <div className="traffic-stats-title">
          <LineChartOutlined />
          <span>流量统计（最近 24 小时）</span>
        </div>
        <div className="traffic-stats-summary">
          <div className="traffic-stats-metrics">
            <span>
              <strong>24h 总流量:</strong> {formatTrafficTotal(stats)}
            </span>
            <span>
              <strong>最近一次:</strong> {lastSampleTotal(stats)}
            </span>
            <span>
              <strong>状态:</strong> {statusLabel}
            </span>
            <Typography.Text type="secondary">更新于 {updatedAt}</Typography.Text>
          </div>
          <Button
            size="small"
            type="text"
            icon={paused ? <CaretRightOutlined /> : <PauseOutlined />}
            onClick={onTogglePause}
            disabled={!enabled}
            title={paused ? "恢复自动刷新" : "暂停自动刷新"}
          />
        </div>
      </div>

      {!enabled ? (
        <div className="traffic-chart-empty">流量统计已关闭，开启后将记录客户端隧道流量</div>
      ) : (
        <TrafficChart stats={stats} />
      )}
    </div>
  );
}
