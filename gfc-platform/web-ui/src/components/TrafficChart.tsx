import { useMemo, useState } from "react";
import dayjs from "dayjs";
import type { FlowStat } from "../types";

type Props = {
  stats: FlowStat[];
  height?: number;
  maxPoints?: number;
};

const VIEW_WIDTH = 1000;

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

export function TrafficChart({ stats, height = 120, maxPoints = 120 }: Props) {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

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

  const max = Math.max(...points.map((p) => p.total), 1);
  const pad = { top: 10, right: 12, bottom: 28, left: 56 };
  const innerW = VIEW_WIDTH - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;

  const coords = points.map((p, i) => {
    const x =
      pad.left +
      (points.length === 1 ? innerW / 2 : (i / (points.length - 1)) * innerW);
    const y = pad.top + innerH - (p.total / max) * innerH;
    return { x, y, p };
  });

  const polyline = coords.map((c) => `${c.x},${c.y}`).join(" ");
  const area =
    `${pad.left},${pad.top + innerH} ` +
    coords.map((c) => `${c.x},${c.y}`).join(" ") +
    ` ${pad.left + innerW},${pad.top + innerH}`;
  const hover = hoverIdx != null ? coords[hoverIdx] : null;

  const xLabelCount = Math.min(6, points.length);
  const xLabelIdx = Array.from({ length: xLabelCount }, (_, i) =>
    Math.round((i / Math.max(xLabelCount - 1, 1)) * (points.length - 1))
  );

  const pickHover = (clientX: number, svg: SVGSVGElement) => {
    const rect = svg.getBoundingClientRect();
    if (rect.width <= 0) return;
    const xInView = ((clientX - rect.left) / rect.width) * VIEW_WIDTH;
    let best = 0;
    let bestDist = Number.POSITIVE_INFINITY;
    coords.forEach((c, i) => {
      const d = Math.abs(c.x - xInView);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    });
    setHoverIdx(best);
  };

  return (
    <div className="traffic-chart">
      <svg
        viewBox={`0 0 ${VIEW_WIDTH} ${height}`}
        width="100%"
        height={height}
        preserveAspectRatio="none"
        onMouseLeave={() => setHoverIdx(null)}
        onMouseMove={(e) => pickHover(e.clientX, e.currentTarget)}
      >
        {/* full-width hit area so hover works anywhere on the chart */}
        <rect
          x={pad.left}
          y={pad.top}
          width={innerW}
          height={innerH}
          fill="transparent"
        />
        {[0, 0.5, 1].map((ratio) => {
          const y = pad.top + innerH * (1 - ratio);
          const val = max * ratio;
          return (
            <g key={ratio}>
              <line
                x1={pad.left}
                x2={VIEW_WIDTH - pad.right}
                y1={y}
                y2={y}
                stroke="#e2e8f0"
              />
              <text x={pad.left - 8} y={y + 4} textAnchor="end" fontSize="11" fill="#64748b">
                {formatBytes(val)}
              </text>
            </g>
          );
        })}
        {xLabelIdx.map((idx) => {
          const x = coords[idx]?.x ?? pad.left;
          return (
            <g key={idx}>
              <text x={x} y={height - 6} textAnchor="middle" fontSize="10" fill="#94a3b8">
                {points[idx]?.label}
              </text>
            </g>
          );
        })}
        <polygon fill="rgba(59,130,246,0.08)" points={area} />
        <polyline fill="none" stroke="#3b82f6" strokeWidth="2" points={polyline} />
        {hover ? (
          <>
            <line
              x1={hover.x}
              x2={hover.x}
              y1={pad.top}
              y2={pad.top + innerH}
              stroke="#94a3b8"
              strokeDasharray="4 4"
            />
            <circle cx={hover.x} cy={hover.y} r={4} fill="#1d4ed8" />
          </>
        ) : null}
      </svg>
      {hover ? (
        <div className="traffic-chart-hover">
          <strong>{hover.p.label}</strong>
          {" · "}总 {formatBytes(hover.p.total)}
          {" · "}下 {formatBytes(hover.p.bytesIn)}
          {" · "}上 {formatBytes(hover.p.bytesOut)}
        </div>
      ) : null}
    </div>
  );
}

export { formatBytes };
