// Adapted from IntelliJ PaintParameters / SimpleGraphCellPainter / PaintUtil,
// Apache-2.0. Mirrors macOS GitGraphGeometry without importing platform code.
// Copyright 2000-2024 JetBrains s.r.o. and contributors.
// See macos/Resources/GitGraph/NOTICE.txt and the owning Git graph Agent Note.
export const GIT_GRAPH_ROW_HEIGHT = 26;
const GRAPH_BASELINE_ROW_HEIGHT = 22;
const GRAPH_MAX_RECOMMENDED_LANES = 6;

export interface GraphPoint {
  x: number;
  y: number;
}
export interface GraphPaintElement {
  position: number;
  adjacentPosition: number;
  direction: "up" | "down";
  isTerminal: boolean;
}

export function gitGraphRowHeight(ascent: number, descent = 0, leading = 0): number {
  return Math.max(
    GIT_GRAPH_ROW_HEIGHT,
    Math.ceil(ascent) + Math.ceil(descent) + Math.ceil(leading) + 7,
  );
}

/** FLOOR / ODD alignment uses device pixels, including fractional Windows scaling. */
export function gitGraphPaintMetrics(rowHeight = GIT_GRAPH_ROW_HEIGHT, backingScale = 1) {
  const scale = Number.isFinite(backingScale) && backingScale > 0 ? backingScale : 1;
  const align = (value: number, odd = false) => {
    let pixels = Math.floor(value * scale);
    if (odd && pixels % 2 === 0) pixels -= 1;
    return pixels / scale;
  };
  const pixel = 1 / scale;
  const rowCenter = align(rowHeight / 2, true);
  const laneSpacing = align((16 * rowHeight) / GRAPH_BASELINE_ROW_HEIGHT, true);
  const laneCenter = align((8 * rowHeight) / GRAPH_BASELINE_ROW_HEIGHT);
  const lineWidth = Math.max(pixel, align((1.5 * rowHeight) / GRAPH_BASELINE_ROW_HEIGHT, true));
  const nodeDiameter = align((8 * rowHeight) / GRAPH_BASELINE_ROW_HEIGHT, true);
  const nodeRadius = align(nodeDiameter / 2);
  const line = (element: GraphPaintElement): { start: GraphPoint; end: GraphPoint } => {
    const gap = element.isTerminal ? nodeRadius / 2 + 1 : 0;
    const endY =
      element.position === element.adjacentPosition
        ? element.direction === "up"
          ? gap
          : rowHeight - gap
        : rowCenter + (element.direction === "up" ? -rowHeight : rowHeight) / 2;
    return {
      start: { x: laneCenter + element.position * laneSpacing, y: rowCenter },
      end: {
        x: laneCenter + ((element.position + element.adjacentPosition) / 2) * laneSpacing,
        y: endY,
      },
    };
  };
  return {
    rowHeight,
    rowCenter,
    laneSpacing,
    laneCenter,
    lineWidth,
    nodeDiameter,
    nodeRadius,
    line,
    nodeRect: (lane: number) => ({
      x: laneCenter + lane * laneSpacing - nodeRadius,
      y: rowCenter - nodeRadius,
      width: nodeDiameter,
      height: nodeDiameter,
    }),
    arrowArms: (element: GraphPaintElement) => {
      const { start, end } = line(element);
      const length = Math.max(1, Math.hypot(end.x - start.x, end.y - start.y));
      const vx = ((start.x - end.x) / length) * rowHeight * 0.3;
      const vy = ((start.y - end.y) / length) * rowHeight * 0.3;
      return [-1, 1].map((sign) => ({
        x: end.x + vx * Math.sqrt(0.7) - sign * vy * Math.sqrt(0.3),
        y: end.y + sign * vx * Math.sqrt(0.3) + vy * Math.sqrt(0.7),
      }));
    },
    arrowHitRect: (element: GraphPaintElement) => {
      const tip = line(element).end;
      const top = element.direction === "up" ? 0 : rowHeight / 2;
      const y = Math.min(top, tip.y - pixel);
      return {
        x: tip.x - 6,
        y,
        width: 12,
        height: Math.max(top + rowHeight / 2, tip.y + pixel) - y,
      };
    },
    dash: (element: GraphPaintElement) => {
      const { start, end } = line(element);
      const length = Math.hypot(end.x - start.x, end.y - start.y) * 2;
      const space = rowHeight / 2 - 2;
      const dash = length / Math.max(1, Math.floor(length / rowHeight)) - space;
      return { dash, space, phase: dash / 2 };
    },
    titleOffset: (lane: number, elements: GraphPaintElement[], recommendedLaneCount = 1) => {
      const last = elements.reduce(
        (value, element) =>
          Math.max(value, element.position, (element.position + element.adjacentPosition) / 2),
        lane,
      );
      // GraphCommitCellUtil caps only the recommended baseline at six columns;
      // each row can extend it for its node and diagonal boundary midpoints.
      const columns = Math.max(last + 1, Math.min(GRAPH_MAX_RECOMMENDED_LANES, recommendedLaneCount));
      return Math.floor(columns * 16 * rowHeight / GRAPH_BASELINE_ROW_HEIGHT)
        + Math.floor(2 * rowHeight / GRAPH_BASELINE_ROW_HEIGHT) + 2;
    },
  };
}

export type GitGraphPaintMetrics = ReturnType<typeof gitGraphPaintMetrics>;
