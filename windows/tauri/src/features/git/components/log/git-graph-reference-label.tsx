import type { GitGraphReferenceMetrics } from "../../hooks/use-git-graph-reference-metrics";
import {
  gitReferenceIconWidth,
  shortenGitReferenceTitle,
  type GitGraphReferenceGroup,
} from "../../utils/git-graph-reference-group";

// Original Community currentBranch / TagPainter geometry, also used by macOS.
// Apache-2.0 attribution: macos/Resources/GitGraph/NOTICE.txt.
const TAG_PATH =
  "M13.4495 7.5001 L7.01028 13.9394 C6.81502 14.1347 6.49843 14.1347 6.30317 13.9394 L2.06053 9.69679 C1.86527 9.50152 1.86527 9.18494 2.06053 8.98968 L8.49978 2.55035 C8.61106 2.43907 8.76824 2.38667 8.92404 2.40893 L12.6363 2.93926 C12.8563 2.97069 13.0292 3.14354 13.0606 3.36352 L13.5909 7.07584 C13.6132 7.23163 13.5608 7.38882 13.4495 7.5001 Z";

export function GitGraphReferenceLabel({
  group,
  subject,
  columnWidth,
  metrics,
}: {
  group: GitGraphReferenceGroup;
  subject: string;
  columnWidth?: number;
  metrics?: GitGraphReferenceMetrics;
}) {
  if (!group.labels.length) return null;
  const iconHeight = metrics?.iconHeight ?? 16;
  const iconWidth = gitReferenceIconWidth(group, iconHeight);
  const available =
    metrics && columnWidth !== undefined
      ? Math.max(0, Math.min(columnWidth - metrics.measureSubject(subject), columnWidth / 3))
      : Infinity;
  const title = metrics
    ? shortenGitReferenceTitle(group.title, available - iconWidth - 9, metrics.measure)
    : group.title;
  const width =
    metrics && columnWidth !== undefined
      ? Math.min(Math.max(0, columnWidth), iconWidth + (title ? metrics.measure(title) + 1 : 0) + 8)
      : undefined;
  return (
    <span
      className="git-graph-reference-group"
      data-git-reference-group=""
      title={group.tooltip}
      role="img"
      aria-label={group.tooltip}
      style={{ width, fontSize: metrics?.fontSize ?? 12 }}
    >
      <svg
        aria-hidden="true"
        className="git-graph-reference-icons"
        width={iconWidth}
        height={iconHeight}
        viewBox={`0 0 ${(iconWidth * 16) / iconHeight} 16`}
      >
        {[...group.iconKinds].reverse().map((kind, index) => (
          <g
            key={`${kind}:${index}`}
            data-reference-kind={kind}
            transform={`translate(${((index * 16) / 6.25) * 2} 0)`}
          >
            <path
              d={TAG_PATH}
              fill="var(--git-log-row-background, var(--background))"
              stroke="currentColor"
              strokeLinejoin="round"
            />
            {index === group.iconKinds.length - 1 && (
              <circle cx="10.5" cy="5.5" r="1" fill="currentColor" />
            )}
          </g>
        ))}
      </svg>
      {title && <span className="git-graph-reference-title">{title}</span>}
    </span>
  );
}
