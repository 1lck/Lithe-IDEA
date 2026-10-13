import { useLayoutEffect, useState, type CSSProperties, type RefObject } from "react";
import { GIT_LOG_MESSAGE_MIN_WIDTH } from "../utils/git-log-columns";
import { useGitGraphTypography } from "./use-git-graph-paint";

export interface GitGraphReferenceMetrics {
  columnWidth: number;
  iconHeight: number;
  fontSize: number;
  measure: (text: string) => number;
  measureSubject: (text: string) => number;
}

/** One viewport observes widths/fonts; mounted rows only consume text metrics. */
export function useGitGraphReferenceMetrics(
  scrollRef: RefObject<HTMLElement | null>,
  columns: CSSProperties,
  rowHeight: number,
): GitGraphReferenceMetrics | undefined {
  const { fontSize: bodySize, family } = useGitGraphTypography();
  const [metrics, setMetrics] = useState<GitGraphReferenceMetrics>();
  useLayoutEffect(() => {
    const element = scrollRef.current;
    if (!element) return;
    let disposed = false;
    let identity = "";
    const measure = () => {
      if (disposed) return;
      const style = getComputedStyle(element);
      const fontSize = Math.max(1, bodySize - 1);
      const columnWidth = Math.max(
        GIT_LOG_MESSAGE_MIN_WIDTH,
        element.clientWidth -
          (parseFloat(style.getPropertyValue("--git-log-author-width")) || 0) -
          (parseFloat(style.getPropertyValue("--git-log-date-width")) || 0),
      );
      const nextIdentity = `${columnWidth}:${fontSize}:${family}:${rowHeight}`;
      if (identity === nextIdentity) return;
      identity = nextIdentity;
      const reference = document.createElement("canvas").getContext("2d");
      const subject = document.createElement("canvas").getContext("2d");
      if (reference) reference.font = `${fontSize}px ${family}`;
      if (subject) subject.font = `${bodySize}px ${family}`;
      const font = reference?.measureText("Hg国");
      const iconHeight =
        font &&
        Number.isFinite(font.fontBoundingBoxAscent) &&
        Number.isFinite(font.fontBoundingBoxDescent)
          ? Math.ceil(font.fontBoundingBoxAscent) + Math.ceil(font.fontBoundingBoxDescent)
          : 16;
      setMetrics({
        columnWidth,
        fontSize,
        iconHeight,
        measure: (text) => reference?.measureText(text).width ?? 0,
        measureSubject: (text) => subject?.measureText(text).width ?? 0,
      });
    };
    measure();
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measure);
    observer?.observe(element);
    const fonts = document.fonts;
    const refreshFonts = () => {
      identity = "";
      measure();
    };
    void fonts?.ready.then(refreshFonts);
    fonts?.addEventListener("loadingdone", refreshFonts);
    return () => {
      disposed = true;
      observer?.disconnect();
      fonts?.removeEventListener("loadingdone", refreshFonts);
    };
  }, [scrollRef, columns, rowHeight, bodySize, family]);
  return metrics;
}
