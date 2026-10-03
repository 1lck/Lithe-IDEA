import type React from "react";
import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import {
  isLabelTruncated,
  measureLabelNaturalWidth,
} from "../components/status/use-git-status-expandable-hint";

/**
 * Width a rendered tree row needs to show its name and count without truncation: the row
 * minus the flexible label area, plus the label parts' natural widths, rounded up with a
 * pixel of slack so fractional text widths never end in an ellipsis. `truncated` tells
 * whether the row is clipped right now.
 */
export function measureTreeRowWidth(row: HTMLElement): { width: number; truncated: boolean } {
  const label = row.querySelector<HTMLElement>("[data-sidebar-tree-label]");
  if (!label) return { width: row.offsetWidth, truncated: false };
  return {
    width: Math.ceil(row.offsetWidth - label.clientWidth + measureLabelNaturalWidth(label)) + 1,
    truncated: isLabelTruncated(label),
  };
}

/**
 * IntelliJ's changes trees scroll horizontally instead of truncating long names. The tree
 * takes the widest width any rendered row has needed; it restarts from the viewport width
 * only when `resetKey` (the layout identity) changes, so routine refreshes do not briefly
 * re-truncate every name. Text widths also change without a React render — the viewport
 * resizes or the UI font finishes loading — so both are observed and re-measured.
 */
export function useTreeContentWidth({
  viewportRef,
  rowSelector,
  resetKey,
  enabled = true,
}: {
  viewportRef: React.RefObject<HTMLElement | null>;
  rowSelector: string;
  /** Identity of the row layout; when it changes, measurement restarts from the viewport width. */
  resetKey: string;
  /** Whether the viewport is (or is about to be) mounted with rows to measure. */
  enabled?: boolean;
}) {
  const [treeContentWidth, setTreeContentWidth] = useState(0);

  const measureTreeContentWidth = useCallback(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    // Only rows that are actually clipped widen the tree, so a tree that fits keeps
    // following the viewport width when its panel is resized.
    let widest = 0;
    for (const row of viewport.querySelectorAll<HTMLElement>(rowSelector)) {
      const { width, truncated } = measureTreeRowWidth(row);
      // A row that is already as wide as it claims to need cannot be helped by growing
      // further; skipping it keeps a mis-measured row from widening the tree forever.
      if (truncated && width > row.offsetWidth + 1) widest = Math.max(widest, width);
    }
    if (widest > 0) setTreeContentWidth((current) => (widest > current ? widest : current));
  }, [rowSelector, viewportRef]);

  useLayoutEffect(() => {
    setTreeContentWidth(0);
  }, [resetKey]);

  useLayoutEffect(() => {
    measureTreeContentWidth();
  });

  useEffect(() => {
    if (!enabled) return;
    const viewport = viewportRef.current;
    const fonts = globalThis.document?.fonts;
    const observer =
      viewport && typeof ResizeObserver !== "undefined"
        ? new ResizeObserver(() => measureTreeContentWidth())
        : null;
    if (viewport) observer?.observe(viewport);
    fonts?.addEventListener?.("loadingdone", measureTreeContentWidth);
    return () => {
      observer?.disconnect();
      fonts?.removeEventListener?.("loadingdone", measureTreeContentWidth);
    };
  }, [enabled, measureTreeContentWidth, viewportRef]);

  return treeContentWidth;
}
