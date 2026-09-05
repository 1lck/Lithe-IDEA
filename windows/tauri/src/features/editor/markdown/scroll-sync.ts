// Scroll-sync primitives for the Markdown split editor. Mirrors the macOS
// MarkdownScrollPosition / MarkdownScrollMetrics contract: both panes report a
// 0..1 scroll ratio through a small dead zone, and the pane whose scroll was
// not the last source adopts the other pane's ratio.
//
// One web-only addition: DOM scroll events for a programmatic apply fire
// asynchronously, so every applied offset is remembered and the matching
// "echo" event is ignored once. Without this the editor/preview pair can
// ping-pong through source flips with sub-pixel rounding differences.

export const MARKDOWN_SCROLL_SYNC_DEAD_ZONE = 0.0005;
export const MARKDOWN_SCROLL_SYNC_ECHO_TOLERANCE_PX = 1;

export interface MarkdownScrollMetrics {
  scrollTop: number;
  scrollHeight: number;
  clientHeight: number;
}

export type MarkdownScrollSyncSource = "editor" | "preview";

export function markdownScrollRatio(metrics: MarkdownScrollMetrics): number {
  const extent = Math.max(0, metrics.scrollHeight - metrics.clientHeight);
  if (extent <= 0 || !Number.isFinite(metrics.scrollTop)) return 0;
  return Math.min(1, Math.max(0, metrics.scrollTop / extent));
}

export function markdownScrollOffset(
  ratio: number,
  scrollHeight: number,
  clientHeight: number,
): number {
  const extent = Math.max(0, scrollHeight - clientHeight);
  const normalized = Math.min(1, Math.max(0, Number.isFinite(ratio) ? ratio : 0));
  return normalized * extent;
}

export class MarkdownScrollSyncController {
  private ratio = 0;
  private source: MarkdownScrollSyncSource | null = null;
  private revision = 0;
  private lastAppliedOffset: Partial<Record<MarkdownScrollSyncSource, number>> = {};

  getSource(): MarkdownScrollSyncSource | null {
    return this.source;
  }

  /**
   * Reports a native scroll from `source`. Returns the ratio the other pane
   * should adopt, or null when the event must not move the other pane: an
   * echo of our own apply, or movement within the dead zone. The dead zone is
   * enforced across source changes as well, otherwise a sub-pixel echo could
   * flip the source and re-drive the other pane in a loop.
   */
  report(source: MarkdownScrollSyncSource, metrics: MarkdownScrollMetrics): number | null {
    if (this.isEcho(source, metrics.scrollTop)) {
      delete this.lastAppliedOffset[source];
      return null;
    }
    const nextRatio = markdownScrollRatio(metrics);
    const delta =
      this.source === null ? Number.POSITIVE_INFINITY : Math.abs(this.ratio - nextRatio);
    if (delta <= MARKDOWN_SCROLL_SYNC_DEAD_ZONE) return null;
    this.ratio = nextRatio;
    this.source = source;
    this.revision += 1;
    return this.ratio;
  }

  /** Records the offset written to a side so its async scroll echo is ignored once. */
  markApplied(side: MarkdownScrollSyncSource, offset: number): void {
    this.lastAppliedOffset[side] = offset;
  }

  private isEcho(side: MarkdownScrollSyncSource, scrollTop: number): boolean {
    const applied = this.lastAppliedOffset[side];
    return (
      applied !== undefined &&
      Math.abs(applied - scrollTop) <= MARKDOWN_SCROLL_SYNC_ECHO_TOLERANCE_PX
    );
  }
}
