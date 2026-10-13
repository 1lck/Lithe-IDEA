export type CommitDiffKind = "inserted" | "deleted" | "modified";

/** IDEA paints an empty range as a thin line rather than a zero-area point. */
export function commitDiffPaintRange(range: readonly [number, number]): readonly [number, number] {
  return range[0] === range[1] ? [range[0] - 1, range[1]] : range;
}

/** Gutters remain rectangular; only the space between them curves (IDEA divider). */
export function commitDiffConnectorPath(
  width: number,
  left: readonly [number, number],
  right: readonly [number, number],
  gutterWidth = 0,
) {
  const gutter = Math.max(0, Math.min(gutterWidth, width / 2));
  const rightEdge = width - gutter;
  const middle = width / 2;
  const a = commitDiffPaintRange(left),
    b = commitDiffPaintRange(right);
  return (
    `M 0 ${a[0]} L ${gutter} ${a[0]} C ${middle} ${a[0]} ${middle} ${b[0]} ${rightEdge} ${b[0]} ` +
    `L ${width} ${b[0]} L ${width} ${b[1]} L ${rightEdge} ${b[1]} ` +
    `C ${middle} ${b[1]} ${middle} ${a[1]} ${gutter} ${a[1]} L 0 ${a[1]} Z`
  );
}

/** Only horizontal boundaries are stroked: no vertical seam at a code/gutter edge.
 * Half-pixel centers match the code pane's one-pixel top/bottom borders.
 */
export function commitDiffConnectorBorderPath(
  width: number,
  left: readonly [number, number],
  right: readonly [number, number],
  gutterWidth: number,
) {
  const gutter = Math.max(0, Math.min(gutterWidth, width / 2));
  const middle = width / 2,
    rightEdge = width - gutter;
  const boundary = (range: readonly [number, number]) =>
    range[0] === range[1] ? [range[0] - 0.5, range[1] + 0.5] : [range[0] + 0.5, range[1] - 0.5];
  const a = boundary(left),
    b = boundary(right);
  return [0, 1]
    .map(
      (edge) =>
        `M 0 ${a[edge]} L ${gutter} ${a[edge]} C ${middle} ${a[edge]} ${middle} ${b[edge]} ${rightEdge} ${b[edge]} L ${width} ${b[edge]}`,
    )
    .join(" ");
}
