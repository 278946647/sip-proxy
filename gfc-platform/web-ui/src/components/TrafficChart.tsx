import { useEffect, useMemo, useRef, useState } from "react";
import dayjs from "dayjs";
import type { FlowStat } from "../types";

type Props = {
  stats: FlowStat[];
  height?: number;
  maxPoints?: number;
};

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

type ChartPoint = FlowStat & { total: number; label: string };

function downsamplePoints(points: ChartPoint[], maxPoints: number): ChartPoint[] {
  if (points.length <= maxPoints) return points;
  const bucket = points.length / maxPoints;
  const out: ChartPoint[] = [];
  for (let i = 0; i < maxPoints; i += 1) {
    const start = Math.floor(i * bucket);
    const end = Math.max(start + 1, Math.floor((i + 1) * bucket));
    const slice = points.slice(start, end);
    out.push(slice.reduce((best, p) => (p.total > best.total ? p : best), slice[0]));
  }
  return out;
}

export function TrafficChart({ stats, height = 220, maxPoints = 120 }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [chartWidth, setChartWidth] = useState(0);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const update = () => setChartWidth(Math.max(el.clientWidth, 1));
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const points = useMemo(() => {
    const raw = stats.map((s) => ({
      ...s,
      total: s.bytesIn + s.bytesOut,
      label: dayjs(s.windowStart).format("MM-DD HH:mm"),
    }));
    return downsamplePoints(raw, maxPoints);
  }, [stats, maxPoints]);

  if (points.length === 0) {
    return <div className="traffic-chart-empty">暂无流量数据</div>;
  }

  const width = chartWidth > 0 ? chartWidth : 1;
  const max = Math.max(...points.map((p) => p.total), 1);
  const pad = { top: 16, right: 8, bottom: 36, left: 52 };
  const innerW = Math.max(width - pad.left - pad.right, 1);
  const innerH = height - pad.top - pad.bottom;

  const coords = points.map((p, i) => {
    const x = pad.left + (points.length === 1 ? innerW / 2 : (i / (points.length - 1)) * innerW);
    const y = pad.top + innerH - (p.total / max) * innerH;
    return { x, y, p };
  });

  const polyline = coords.map((c) => `${c.x},${c.y}`).join(" ");
  const hover = hoverIdx != null ? coords[hoverIdx] : null;

  const xLabelCount = Math.min(8, points.length);
  const xLabelIdx = Array.from({ length: xLabelCount }, (_, i) =>
    Math.round((i / Math.max(xLabelCount - 1, 1)) * (points.length - 1))
  );

  return (
    <div className="traffic-chart" ref={containerRef}>
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
              <text x={pad.left - 6} y={y + 4} textAnchor="end" fontSize="11" fill="#64748b">
                {formatBytes(val)}
              </text>
            </g>
          );
        })}
        {xLabelIdx.map((idx) => {
          const x = coords[idx]?.x ?? pad.left;
          return (
            <g key={idx}>
              <line x1={x} x2={x} y1={pad.top} y2={pad.top + innerH} stroke="#f1f5f9" />
              <text x={x} y={height - 10} textAnchor="middle" fontSize="10" fill="#94a3b8">
                {points[idx]?.label}
              </text>
            </g>
          );
        })}
        <polyline fill="none" stroke="#3b82f6" strokeWidth="1.75" points={polyline} />
        {coords.map((c, i) => (
          <circle
            key={`${c.p.id}-${i}`}
            cx={c.x}
            cy={c.y}
            r={hoverIdx === i ? 4 : 0}
            fill="#1d4ed8"
            onMouseEnter={() => setHoverIdx(i)}
          />
        ))}
        {hover ? (
          <line
            x1={hover.x}
            x2={hover.x}
            y1={pad.top}
            y2={pad.top + innerH}
            stroke="#94a3b8"
            strokeDasharray="4 4"
          />
        ) : null}
      </svg>
      {hover ? (
        <div className="traffic-chart-hover">
          <strong>{hover.p.label}</strong>
          {" · "}总流量 {formatBytes(hover.p.total)}
          {" · "}下行 {formatBytes(hover.p.bytesIn)}
          {" · "}上行 {formatBytes(hover.p.bytesOut)}
        </div>
      ) : (
        <div className="traffic-chart-hint">鼠标悬停折线查看该时段详情（展示已抽样，最多 {maxPoints} 点）</div>
      )}
    </div>
  );
}

export { formatBytes };
