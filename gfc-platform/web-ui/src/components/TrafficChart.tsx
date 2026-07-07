import { useMemo, useState } from "react";
import dayjs from "dayjs";
import type { FlowStat } from "../types";

type Props = {
  stats: FlowStat[];
  height?: number;
};

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

export function TrafficChart({ stats, height = 220 }: Props) {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  const points = useMemo(
    () =>
      stats.map((s) => ({
        ...s,
        total: s.bytesIn + s.bytesOut,
        label: dayjs(s.windowStart).format("MM-DD HH:mm"),
      })),
    [stats]
  );

  if (points.length === 0) {
    return <div style={{ color: "#64748b", padding: "24px 0" }}>暂无流量数据</div>;
  }

  const max = Math.max(...points.map((p) => p.total), 1);
  const width = 900;
  const pad = { top: 16, right: 16, bottom: 28, left: 56 };
  const innerW = width - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;

  const coords = points.map((p, i) => {
    const x = pad.left + (points.length === 1 ? innerW / 2 : (i / (points.length - 1)) * innerW);
    const y = pad.top + innerH - (p.total / max) * innerH;
    return { x, y, p };
  });

  const polyline = coords.map((c) => `${c.x},${c.y}`).join(" ");
  const hover = hoverIdx != null ? coords[hoverIdx] : null;

  return (
    <div>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        width="100%"
        height={height}
        onMouseLeave={() => setHoverIdx(null)}
      >
        {[0, 0.5, 1].map((ratio) => {
          const y = pad.top + innerH * (1 - ratio);
          const val = max * ratio;
          return (
            <g key={ratio}>
              <line x1={pad.left} x2={width - pad.right} y1={y} y2={y} stroke="#e2e8f0" />
              <text x={pad.left - 8} y={y + 4} textAnchor="end" fontSize="11" fill="#64748b">
                {formatBytes(val)}
              </text>
            </g>
          );
        })}
        <polyline fill="none" stroke="#3b82f6" strokeWidth="2" points={polyline} />
        {coords.map((c, i) => (
          <circle
            key={c.p.id}
            cx={c.x}
            cy={c.y}
            r={hoverIdx === i ? 5 : 3}
            fill={hoverIdx === i ? "#1d4ed8" : "#3b82f6"}
            onMouseEnter={() => setHoverIdx(i)}
          />
        ))}
        {hover ? (
          <g>
            <line x1={hover.x} x2={hover.x} y1={pad.top} y2={pad.top + innerH} stroke="#94a3b8" strokeDasharray="4 4" />
          </g>
        ) : null}
      </svg>
      {hover ? (
        <div style={{ marginTop: 8, fontSize: 13, color: "#334155" }}>
          <strong>{hover.p.label}</strong>
          {" · "}总流量 {formatBytes(hover.p.total)}
          {" · "}下行 {formatBytes(hover.p.bytesIn)}
          {" · "}上行 {formatBytes(hover.p.bytesOut)}
        </div>
      ) : (
        <div style={{ marginTop: 8, fontSize: 12, color: "#64748b" }}>
          鼠标悬停数据点查看该时段详情（采样间隔约 10 秒）
        </div>
      )}
    </div>
  );
}
