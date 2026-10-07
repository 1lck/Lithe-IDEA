import { memo, type CSSProperties } from "react";
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

export const GitGraphRow = memo(function GitGraphRow({
  row,
  showDecorations,
  paint = DEFAULT_PAINT,
  onNavigateHash,
  referenceGroup,
  referenceMetrics,
}: {
  row: GraphRow;
  showDecorations: boolean;
  paint?: GitGraphPaintMetrics;
  onNavigateHash?: (hash: string) => void;
  referenceGroup?: GitGraphReferenceGroup;
  referenceMetrics?: GitGraphReferenceMetrics;
}) {
  const width = paint.titleOffset(row.lane, row.printElements);
  const node = paint.nodeRect(row.lane);

  return (
    <>
      <svg
        aria-hidden="true"
        width={width}
        height={paint.rowHeight}
        className="pointer-events-none shrink-0 overflow-visible"
      >
        {row.printElements.map((segment) => {
          const { start, end } = paint.line(segment);
          const dash = segment.isDotted && !segment.hasArrow ? paint.dash(segment) : undefined;
          const arms = segment.hasArrow ? paint.arrowArms(segment) : [];
          const path = [
            `M ${start.x} ${start.y} L ${end.x} ${end.y}`,
            ...arms.map((arm) => `M ${end.x} ${end.y} L ${arm.x} ${arm.y}`),
          ].join(" ");
          return (
            <path
              key={segment.id}
              d={path}
              fill="none"
              className="git-graph-tone"
              style={tone(segment.colorIndex)}
              stroke="currentColor"
              strokeWidth={paint.lineWidth}
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeDasharray={dash ? `${dash.dash} ${dash.space}` : undefined}
              strokeDashoffset={dash?.phase}
            />
          );
        })}
        <ellipse
          cx={node.x + node.width / 2}
          cy={node.y + node.height / 2}
          rx={node.width / 2}
          ry={node.height / 2}
          className="git-graph-tone"
          style={tone(row.colorIndex)}
          fill="currentColor"
        />
      </svg>
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
