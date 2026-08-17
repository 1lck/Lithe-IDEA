import { cn } from "@/utils/cn";
import type { GitGraphLabel, GitGraphRow as GraphRow } from "../../utils/git-graph-layout";

const ROW_HEIGHT = 30;
const LANE_GAP = 13;
const GRAPH_PADDING = 8;
const GRAPH_COLORS = ["#55d68b", "#65a9ff", "#d77eea", "#f3aa59", "#e76c72", "#56c7cf"];

function graphColor(index: number) {
  return GRAPH_COLORS[index % GRAPH_COLORS.length];
}

export function gitGraphLabelClassName(label: GitGraphLabel) {
  switch (label.kind) {
    case "head":
      return "border-sky-700/35 bg-sky-500/18 text-sky-800 dark:border-sky-400/45 dark:bg-sky-500/20 dark:text-sky-200";
    case "remote":
      return "border-indigo-700/35 bg-indigo-500/18 text-indigo-800 dark:border-indigo-400/45 dark:bg-indigo-500/20 dark:text-indigo-200";
    case "tag":
      return "border-amber-700/40 bg-amber-500/20 text-amber-900 dark:border-amber-400/45 dark:bg-amber-500/20 dark:text-amber-200";
    default:
      return "border-emerald-700/35 bg-emerald-500/18 text-emerald-800 dark:border-emerald-400/45 dark:bg-emerald-500/20 dark:text-emerald-200";
  }
}

export function GitGraphRow({ row, showDecorations }: { row: GraphRow; showDecorations: boolean }) {
  const width = Math.max(30, row.laneCount * LANE_GAP + GRAPH_PADDING * 2);
  const nodeX = GRAPH_PADDING + row.lane * LANE_GAP;
  const middleY = ROW_HEIGHT / 2;

  return (
    <>
      <svg
        aria-hidden="true"
        width={width}
        height={ROW_HEIGHT}
        className="shrink-0 overflow-visible"
      >
        {row.incomingLaneColors.map((colorIndex, lane) => {
          if (colorIndex === null) return null;
          const x = GRAPH_PADDING + lane * LANE_GAP;
          return (
            <line
              key={`incoming:${lane}`}
              x1={x}
              y1={0}
              x2={x}
              y2={lane === row.lane ? middleY : ROW_HEIGHT}
              stroke={graphColor(colorIndex)}
              strokeWidth={1.6}
            />
          );
        })}
        {row.parentEdges.map((edge) => {
          const targetX =
            edge.targetLane === null ? nodeX : GRAPH_PADDING + edge.targetLane * LANE_GAP;
          return (
            <path
              key={edge.id}
              d={`M ${nodeX} ${middleY} C ${nodeX} ${middleY + 7}, ${targetX} ${ROW_HEIGHT - 7}, ${targetX} ${ROW_HEIGHT}`}
              fill="none"
              stroke={graphColor(edge.colorIndex)}
              strokeWidth={1.6}
              strokeDasharray={edge.isMissing ? "3 2" : undefined}
              opacity={edge.isMissing ? 0.7 : 1}
            />
          );
        })}
        <circle
          cx={nodeX}
          cy={middleY}
          r={4.3}
          fill="var(--background)"
          stroke={graphColor(
            row.incomingLaneColors[row.lane] ?? row.parentEdges[0]?.colorIndex ?? 0,
          )}
          strokeWidth={2}
        />
      </svg>

      <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden">
        {showDecorations &&
          row.labels.map((label, index) => (
            <span
              key={`${label.kind}:${label.title}:${index}`}
              className={cn(
                "max-w-28 shrink-0 truncate rounded border px-1.5 py-0.5 font-medium text-[10px] leading-none",
                gitGraphLabelClassName(label),
              )}
              title={label.title}
            >
              {label.title}
            </span>
          ))}
        <span className="min-w-0 flex-1 truncate text-foreground" title={row.commit.message}>
          {row.commit.message}
        </span>
      </div>
    </>
  );
}
