import { useEffect } from "react";

/** Gap between label parts (name, count or directory), matching SidebarTreeRow's gap-1.5. */
const LABEL_PART_GAP = 6;
/** Horizontal padding of the hint around the copied label. */
const HINT_PADDING_X = 4;

/**
 * Fractional width of a label part's text. `scrollWidth` is rounded to whole pixels, so a
 * name overflowing by a fraction of a pixel still gets an ellipsis while reading as
 * fitting; a range around the text reports the real laid-out width. Environments without
 * layout (tests) fall back to `scrollWidth`.
 */
function measureTextWidth(part: HTMLElement): number {
  const range = part.ownerDocument.createRange?.();
  range?.selectNodeContents(part);
  const textWidth = range?.getBoundingClientRect().width ?? 0;
  // Never fall back to scrollWidth when real layout exists: a stretched flex part reports
  // its box width there, which grows with the tree and would keep widening it.
  return textWidth > 0 ? textWidth : part.scrollWidth;
}

/**
 * Layout snaps boxes to 1/64px while a text range is fractional, so differences below
 * this are measurement noise rather than truncation.
 */
const TRUNCATION_TOLERANCE = 0.05;

/** Natural width of a tree row label: every part at full text width plus the gaps between. */
export function measureLabelNaturalWidth(label: HTMLElement): number {
  const parts = Array.from(label.children) as HTMLElement[];
  return (
    parts.reduce((total, part) => total + measureTextWidth(part), 0) +
    LABEL_PART_GAP * Math.max(0, parts.length - 1)
  );
}

/** Whether any label part is narrower than its text, i.e. truncated or ellipsized. */
export function isLabelTruncated(label: HTMLElement): boolean {
  return (Array.from(label.children) as HTMLElement[]).some((part) => {
    const available = part.getBoundingClientRect().width || part.clientWidth;
    return (
      measureTextWidth(part) > available + TRUNCATION_TOLERANCE ||
      part.scrollWidth > part.clientWidth
    );
  });
}

/** Whether a label starting at `labelLeft` runs past the visible right edge of its viewport. */
export function isLabelCutOff(labelLeft: number, naturalWidth: number, visibleRight: number) {
  return labelLeft + naturalWidth > visibleRight + 1;
}

/**
 * IntelliJ's ExpandableItemsHandler for the changes tree: hovering a row whose name or
 * count is cut off by the viewport edge (or ellipsized) shows the whole label in a hint
 * drawn over the row and past the panel edge. The hint is a static copy of the label,
 * positioned with fixed coordinates and ignoring the pointer, so it never steals hover,
 * clicks or drags from the row; it hides on leave, scroll, wheel and press.
 */
export function useGitStatusExpandableHint(
  viewportRef: React.RefObject<HTMLElement | null>,
  enabled: boolean,
) {
  useEffect(() => {
    const viewport = viewportRef.current;
    if (!enabled || !viewport) return;

    const hint = document.createElement("div");
    hint.dataset.gitStatusExpandableHint = "";
    hint.setAttribute("aria-hidden", "true");
    hint.className =
      "pointer-events-none fixed z-50 flex items-center whitespace-nowrap rounded-[4px] border border-control-border bg-background text-foreground shadow-md";
    hint.style.display = "none";
    hint.style.paddingInline = `${HINT_PADDING_X}px`;
    document.body.append(hint);

    let currentRow: HTMLElement | null = null;
    const hide = () => {
      currentRow = null;
      hint.style.display = "none";
      hint.replaceChildren();
    };

    const show = (row: HTMLElement) => {
      const label = row.querySelector<HTMLElement>("[data-sidebar-tree-label]");
      if (!label) return hide();
      const viewportRect = viewport.getBoundingClientRect();
      const labelRect = label.getBoundingClientRect();
      const rowRect = row.getBoundingClientRect();
      const naturalWidth = measureLabelNaturalWidth(label);
      const truncated = isLabelTruncated(label);
      // clientWidth excludes the overlay scrollbar gutter, so the cut-off edge is exact.
      const visibleRight = viewportRect.left + viewport.clientWidth;
      if (!truncated && !isLabelCutOff(labelRect.left, naturalWidth, visibleRight)) {
        return hide();
      }

      const copy = label.cloneNode(true) as HTMLElement;
      copy.removeAttribute("data-sidebar-tree-label");
      copy.style.overflow = "visible";
      copy.style.flex = "none";
      for (const part of Array.from(copy.querySelectorAll<HTMLElement>("*"))) {
        part.style.overflow = "visible";
        part.style.textOverflow = "clip";
        part.style.flex = "none";
        part.style.maxWidth = "none";
      }
      const font = getComputedStyle(label);
      hint.style.fontSize = font.fontSize;
      hint.style.fontFamily = font.fontFamily;
      hint.style.left = `${labelRect.left - HINT_PADDING_X - 1}px`;
      hint.style.top = `${rowRect.top}px`;
      hint.style.height = `${rowRect.height}px`;
      hint.replaceChildren(copy);
      hint.style.display = "flex";
      currentRow = row;
    };

    const handlePointerOver = (event: PointerEvent) => {
      const row = (event.target as Element | null)?.closest?.<HTMLElement>(
        "[data-git-status-row-index]",
      );
      if (!row || !viewport.contains(row)) return hide();
      if (row !== currentRow) show(row);
    };

    viewport.addEventListener("pointerover", handlePointerOver);
    viewport.addEventListener("pointerleave", hide);
    viewport.addEventListener("pointerdown", hide);
    viewport.addEventListener("scroll", hide, { passive: true });
    viewport.addEventListener("wheel", hide, { passive: true });
    window.addEventListener("blur", hide);
    return () => {
      viewport.removeEventListener("pointerover", handlePointerOver);
      viewport.removeEventListener("pointerleave", hide);
      viewport.removeEventListener("pointerdown", hide);
      viewport.removeEventListener("scroll", hide);
      viewport.removeEventListener("wheel", hide);
      window.removeEventListener("blur", hide);
      hint.remove();
    };
  }, [enabled, viewportRef]);
}
