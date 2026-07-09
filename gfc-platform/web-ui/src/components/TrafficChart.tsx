import { useMemo, useState, type MouseEvent } from "react";
import dayjs from "dayjs";
import type { FlowStat } from "../types";

type Props = {
  stats: FlowStat[];
  height?: number;
};

const VIEW_WIDTH = 1000;
const MIB = 1024 * 1024;

export function flowRateMBps(bytesIn: number, bytesOut: number, windowSeconds: number) {
  const sec = Math.max(windowSeconds, 1);
  return (bytesIn + bytesOut) / sec / MIB;
}

export function formatRateMBps(rate: number) {
  if (!Number.isFinite(rate) || rate <= 0) return "0 MB/s";
  if (rate < 0.01) return `${(rate * 1024).toFixed(1)} KB/s`;
  if (rate < 10) return `${rate.toFixed(2)} MB/s`;
  return `${rate.toFixed(1)} MB/s`;
}

function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} MB`;
  return `${(n / 1024 ** 3).toFixed(2)} GB`;
}

type ChartPoint = FlowStat & {
  rateMBps: number;
  label: string;
};

function smoothRates(values: number[]): number[] {
  if (values.length <= 2) return values;
  return values.map((v, i) => {
    const prev = values[Math.max(0, i - 1)];
    const next = values[Math.min(values.length - 1, i + 1)];
    return (prev + v + next) / 3;
  });
}

function xLabelAnchor(idx: number, lastIdx: number): "start" | "middle" | "end" {
  if (idx <= 0) return "start";
  if (idx >= lastIdx) return "end";
  return "middle";
}

export function TrafficChart({ stats, height = 140 }: Props) {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  const points = useMemo(() => {
    const raw: ChartPoint[] = stats.map((s) => ({
      ...s,
      rateMBps: flowRateMBps(s.bytesIn, s.bytesOut, s.windowSeconds),
      label: dayjs(s.windowStart).format("MM-DD HH:mm"),
    }));
    const smoothed = smoothRates(raw.map((p) => p.rateMBps));
    return raw.map((p, i) => ({ ...p, rateMBps: smoothed[i] }));
  }, [stats]);

  if (points.length === 0) {
    return <div className="traffic-chart-empty">暂无 gfctun 流量数据</div>;
  }

  const max = Math.max(...points.map((p) => p.rateMBps), 0.001);
  const pad = { top: 12, right: 28, bottom: 30, left: 64 };
  const innerW = VIEW_WIDTH - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;

  const coords = points.map((p, i) => {
    const x =
      pad.left +
      (points.length === 1 ? innerW / 2 : (i / (points.length - 1)) * innerW);
    const y = pad.top + innerH - (p.rateMBps / max) * innerH;
    return { x, y, p };
  });

  const polyline = coords.map((c) => `${c.x},${c.y}`).join(" ");
  const area =
    `${pad.left},${pad.top + innerH} ` +
    coords.map((c) => `${c.x},${c.y}`).join(" ") +
    ` ${pad.left + innerW},${pad.top + innerH}`;
  const hover = hoverIdx != null ? coords[hoverIdx] : null;

  const xLabelCount = Math.min(8, points.length);
  const xLabelIdx = Array.from({ length: xLabelCount }, (_, i) =>
    Math.round((i / Math.max(xLabelCount - 1, 1)) * (points.length - 1))
  );
  const lastLabelIdx = xLabelIdx[xLabelIdx.length - 1] ?? 0;

  const yTicks = [0, 0.25, 0.5, 0.75, 1];

  const pickHover = (e: MouseEvent<SVGSVGElement>) => {
    const svg = e.currentTarget;
    const ctm = svg.getScreenCTM();
    if (!ctm) return;
    const pt = svg.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    const local = pt.matrixTransform(ctm.inverse());
    let best = 0;
    let bestDist = Number.POSITIVE_INFINITY;
    coords.forEach((c, i) => {
      const d = Math.abs(c.x - local.x);
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
        onMouseMove={pickHover}
      >
        <rect
          x={pad.left}
          y={pad.top}
          width={innerW}
          height={innerH}
          fill="transparent"
        />
        {yTicks.map((ratio) => {
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
                {formatRateMBps(val)}
              </text>
            </g>
          );
        })}
        {xLabelIdx.map((idx) => {
          const x = coords[idx]?.x ?? pad.left;
          const anchor = xLabelAnchor(idx, lastLabelIdx);
          return (
            <g key={idx}>
              <text
                x={x}
                y={height - 8}
                textAnchor={anchor}
                fontSize="10"
                fill="#94a3b8"
              >
                {points[idx]?.label}
              </text>
            </g>
          );
        })}
        <polygon fill="rgba(59,130,246,0.08)" points={area} />
        <polyline
          fill="none"
          stroke="#3b82f6"
          strokeWidth="2"
          strokeLinejoin="round"
          strokeLinecap="round"
          points={polyline}
        />
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
          {" · "}速率 {formatRateMBps(flowRateMBps(hover.p.bytesIn, hover.p.bytesOut, hover.p.windowSeconds))}
          {" · "}下 {formatBytes(hover.p.bytesIn)}
          {" · "}上 {formatBytes(hover.p.bytesOut)}
        </div>
      ) : null}
    </div>
  );
}

export { formatBytes };
