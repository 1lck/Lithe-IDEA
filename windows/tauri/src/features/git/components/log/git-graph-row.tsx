import { memo, useId, type CSSProperties } from "react";
import { graphColor } from "../../utils/git-graph-colors";
import type { GitGraphRow as GraphRow } from "../../utils/git-graph-layout";
import {
  groupGitGraphReferences,
  type GitGraphReferenceGroup,
} from "../../utils/git-graph-reference-group";
import type { GitGraphReferenceMetrics } from "../../hooks/use-git-graph-reference-metrics";
import { GitGraphReferenceLabel } from "./git-graph-reference-label";
import { gitGraphPaintMetrics, type GitGraphPaintMetrics } from "../../utils/git-graph-geometry";
import "./git-graph.css";
import { useTranslation } from "@/i18n/locale-provider";

const DEFAULT_PAINT = gitGraphPaintMetrics();
const tone = (colorId: number) =>
  ({
    "--git-graph-light": graphColor(colorId),
    "--git-graph-dark": graphColor(colorId, true),
  }) as CSSProperties;

export function gitGraphWidth(
  rows: readonly GraphRow[],
  paint: GitGraphPaintMetrics,
  recommendedLaneCount = 1,
): number {
  return rows.reduce(
    (width, row) => Math.max(width, paint.titleOffset(row.lane, row.printElements, recommendedLaneCount)),
    0,
  );
}

export const GitGraphRow = memo(function GitGraphRow({
  row,
  showDecorations,
  paint = DEFAULT_PAINT,
  onNavigateHash,
  referenceGroup,
  referenceMetrics,
  recommendedLaneCount = 1,
}: {
  row: GraphRow;
  showDecorations: boolean;
  paint?: GitGraphPaintMetrics;
  onNavigateHash?: (hash: string) => void;
  referenceGroup?: GitGraphReferenceGroup;
  referenceMetrics?: GitGraphReferenceMetrics;
  recommendedLaneCount?: number;
}) {
  const width = paint.titleOffset(row.lane, row.printElements, recommendedLaneCount);

  return (
    <>
      <div
        aria-hidden="true"
        className="git-graph-row-spacer shrink-0"
        style={{ width, height: paint.rowHeight }}
      />
      {onNavigateHash && (
        <GitGraphArrowTargets row={row} paint={paint} onNavigateHash={onNavigateHash} />
      )}

      <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-clip">
        <span
          className="git-log-commit-text min-w-0 flex-1 overflow-clip text-ellipsis whitespace-nowrap text-foreground"
          title={row.commit.message}
        >
          {row.commit.message}
        </span>
        {showDecorations && (
          <GitGraphReferenceLabel
            group={referenceGroup ?? groupGitGraphReferences(row.labels)}
            subject={row.commit.message}
            metrics={referenceMetrics}
            columnWidth={referenceMetrics ? referenceMetrics.columnWidth - width : undefined}
          />
        )}
      </div>
    </>
  );
});

/** Draw the graph on one surface so row virtualization and CSS backgrounds cannot split edges. */
export const GitGraphCanvas = memo(function GitGraphCanvas({
  rows,
  rowOffset = 0,
  paint,
  graphWidth,
}: {
  rows: readonly GraphRow[];
  rowOffset?: number;
  paint: GitGraphPaintMetrics;
  graphWidth: number;
}) {
  const headEdgesClipId = useId();
  if (rows.length === 0) return null;
  const height = rows.length * paint.rowHeight;
  const clipMargin = paint.rowHeight;
  const headCutouts = rows.flatMap((row, rowIndex) => {
    if (!row.labels.some((label) => label.kind === "head")) return [];
    const node = paint.headNodeRect(row.lane);
    const x = node.x;
    const y = node.y + node.height / 2 + rowIndex * paint.rowHeight;
    const radius = node.width / 2;
    return [`M ${x} ${y} a ${radius} ${radius} 0 1 0 ${node.width} 0 a ${radius} ${radius} 0 1 0 ${-node.width} 0 Z`];
  });
  return (
    <svg
      aria-hidden="true"
      data-git-graph-canvas="true"
      className="git-graph-canvas pointer-events-none"
      width={graphWidth}
      height={height}
      viewBox={`0 0 ${graphWidth} ${height}`}
      style={{ top: rowOffset * paint.rowHeight }}
    >
      <g data-git-graph-edges="true" clipPath={headCutouts.length ? `url(#${headEdgesClipId})` : undefined}>
        {buildGraphPaths(rows, paint, rowOffset).map((path) => (
          <path
            key={path.id}
            d={path.d}
            fill="none"
            className="git-graph-tone"
            style={tone(path.colorIndex)}
            stroke="currentColor"
            strokeWidth={paint.lineWidth}
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeDasharray={path.dash ? `${path.dash.dash} ${path.dash.space}` : undefined}
            strokeDashoffset={path.dash?.phase}
          />
        ))}
      </g>
      {rows.map((row, rowIndex) => {
        const isHead = row.labels.some((label) => label.kind === "head");
        const node = isHead ? paint.headNodeRect(row.lane) : paint.nodeRect(row.lane);
        const top = rowIndex * paint.rowHeight;
        const radius = (node.width - (isHead ? paint.headRingWidth : 0)) / 2;
        return (
          <g key={row.commit.hash} transform={`translate(0 ${top})`}>
            <ellipse
              cx={node.x + node.width / 2}
              cy={node.y + node.height / 2}
              rx={radius}
              ry={radius}
              className="git-graph-tone"
              style={tone(row.colorIndex)}
              fill={isHead ? "none" : "currentColor"}
              stroke={isHead ? "currentColor" : undefined}
              strokeWidth={isHead ? paint.headRingWidth : undefined}
            />
            {isHead && (
              <ellipse
                cx={node.x + node.width / 2}
                cy={node.y + node.height / 2}
                rx={paint.headInnerDiameter / 2}
                ry={paint.headInnerDiameter / 2}
                className="git-graph-tone"
                style={tone(row.colorIndex)}
                fill="currentColor"
              />
            )}
          </g>
        );
      })}
      {headCutouts.length > 0 && (
        <defs>
          <clipPath id={headEdgesClipId} clipPathUnits="userSpaceOnUse">
            {/* Reveal the real row background through HEAD, including hover and selection. */}
            <path
              clipRule="evenodd"
              d={`M ${-clipMargin} ${-clipMargin} H ${graphWidth + clipMargin} V ${height + clipMargin} H ${-clipMargin} Z ${headCutouts.join(" ")}`}
            />
          </clipPath>
        </defs>
      )}
    </svg>
  );
});

type GraphPath = {
  id: string;
  d: string;
  colorIndex: number;
  dash?: ReturnType<GitGraphPaintMetrics["dash"]>;
};

function buildGraphPaths(
  rows: readonly GraphRow[],
  paint: GitGraphPaintMetrics,
  rowOffset: number,
): GraphPath[] {
  const segments = new Map<
    string,
    { rowIndex: number; segment: GraphRow["printElements"][number] }[]
  >();
  rows.forEach((row, rowIndex) => {
    row.printElements.forEach((segment) => {
      // Edge ids contain colons (row, parent and hash). Only the final
      // direction suffix identifies the half-edge; splitting at the first
      // colon merges unrelated forks from the same row.
      const edgeId = segment.id.slice(0, segment.id.lastIndexOf(":"));
      const list = segments.get(edgeId) ?? [];
      list.push({ rowIndex, segment });
      segments.set(edgeId, list);
    });
  });

  return [...segments.entries()].flatMap(([edgeId, values]) => {
    const byRowAndDirection = new Map(
      values.map((value) => [`${value.rowIndex}:${value.segment.direction}`, value.segment]),
    );
    const paths: GraphPath[] = [];
    const consumed = new Set<string>();
    values.forEach(({ rowIndex, segment }) => {
      const key = `${rowIndex}:${segment.id}`;
      if (consumed.has(key)) return;
      const start = paint.line(segment);
      const top = rowIndex * paint.rowHeight;
      const points = [
        `M ${start.start.x} ${start.start.y + top}`,
        `L ${start.end.x} ${start.end.y + top}`,
      ];
      const next = segment.direction === "down"
        ? byRowAndDirection.get(`${rowIndex + 1}:up`)
        : undefined;
      if (next) {
        const nextLine = paint.line(next);
        const nextTop = (rowIndex + 1) * paint.rowHeight;
        points.push(`L ${nextLine.start.x} ${nextLine.start.y + nextTop}`);
        consumed.add(`${rowIndex + 1}:${next.id}`);
        if (next.hasArrow) {
          paint.arrowArms(next).forEach((arm) =>
            points.push(
              `M ${nextLine.end.x} ${nextLine.end.y + nextTop} L ${arm.x} ${arm.y + nextTop}`,
            ),
          );
        }
      }
      if (segment.hasArrow) {
        paint.arrowArms(segment).forEach((arm) =>
          points.push(`M ${start.end.x} ${start.end.y + top} L ${arm.x} ${arm.y + top}`),
        );
      }
      consumed.add(key);
      paths.push({
        id: `${edgeId}:${rowIndex + rowOffset}:${segment.direction}`,
        d: points.join(" "),
        colorIndex: segment.colorIndex,
        dash: segment.isDotted && !segment.hasArrow && !next?.hasArrow ? paint.dash(segment) : undefined,
      });
    });
    return paths;
  });
}

function GitGraphArrowTargets({
  row,
  paint,
  onNavigateHash,
}: {
  row: GraphRow;
  paint: GitGraphPaintMetrics;
  onNavigateHash: (hash: string) => void;
}) {
  const { t } = useTranslation();
  return row.printElements
    .filter((element) => element.hasArrow && element.targetHash !== null)
    .map((element) => {
      const target = element.targetHash!;
      const rect = paint.arrowHitRect(element);
      const label = t(element.direction === "down" ? "git.log.goToParent" : "git.log.goToChild", {
        hash: target.slice(0, 8),
      });
      return (
        <button
          key={element.id}
          type="button"
          aria-label={label}
          title={label}
          data-git-graph-target={target}
          className="absolute cursor-pointer border-0 bg-transparent p-0 outline-none focus-visible:ring-1 focus-visible:ring-primary"
          style={{ left: rect.x, top: rect.y, width: rect.width, height: rect.height }}
          onClick={(event) => {
            event.stopPropagation();
            onNavigateHash(target);
          }}
          onDoubleClick={(event) => event.stopPropagation()}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") event.stopPropagation();
          }}
        />
      );
    });
}
