import { useEffect, useMemo, useState } from "react";
import {
  DEFAULT_UI_FONT_FAMILY,
  getTypographyFontFallbacks,
} from "@/features/settings/config/typography-defaults";
import { buildFontFamilyStack } from "@/features/settings/lib/font-family-resolution";
import { normalizeUiFontSize } from "@/features/settings/lib/ui-font-size";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { IS_WINDOWS } from "@/utils/platform";
import { gitGraphPaintMetrics, gitGraphRowHeight } from "../utils/git-graph-geometry";

const readScale = () =>
  typeof window === "undefined" ||
  !Number.isFinite(window.devicePixelRatio) ||
  window.devicePixelRatio <= 0
    ? 1
    : window.devicePixelRatio;

/** Shared font resolution for graph geometry and compact reference text. */
export function useGitGraphTypography() {
  const requestedSize = useSettingsStore((state) => state.settings.uiFontSize);
  const requestedFamily = useSettingsStore((state) => state.settings.uiFontFamily);
  const fontSize = normalizeUiFontSize(requestedSize);
  const family = buildFontFamilyStack(
    requestedFamily || DEFAULT_UI_FONT_FAMILY,
    getTypographyFontFallbacks(IS_WINDOWS).sans,
  );
  return { fontSize, family };
}

/** One viewport owns font/DPI observation; rows only receive immutable paint metrics. */
export function useGitGraphPaint() {
  const { fontSize, family } = useGitGraphTypography();
  const [measuredHeight, setMeasuredHeight] = useState(gitGraphRowHeight(fontSize));
  const [scale, setScale] = useState(readScale);

  useEffect(() => {
    let disposed = false;
    const context = document.createElement("canvas").getContext("2d");
    const measure = () => {
      if (disposed) return;
      let height = gitGraphRowHeight(fontSize);
      if (context) {
        context.font = `${fontSize}px ${family}`;
        const metrics = context.measureText("Hg国");
        if (
          Number.isFinite(metrics.fontBoundingBoxAscent) &&
          Number.isFinite(metrics.fontBoundingBoxDescent)
        ) {
          height = gitGraphRowHeight(metrics.fontBoundingBoxAscent, metrics.fontBoundingBoxDescent);
        }
      }
      setMeasuredHeight((current) => (current === height ? current : height));
    };
    measure();
    const fonts = document.fonts;
    void fonts?.ready.then(measure);
    fonts?.addEventListener("loadingdone", measure);
    return () => {
      disposed = true;
      fonts?.removeEventListener("loadingdone", measure);
    };
  }, [fontSize, family]);

  useEffect(() => {
    let watchedScale = 0;
    let query: MediaQueryList | undefined;
    const update = () => {
      const next = readScale();
      if (watchedScale === next) return;
      watchedScale = next;
      setScale(next);
      query?.removeEventListener("change", update);
      query = window.matchMedia?.(`(resolution: ${next}dppx)`);
      query?.addEventListener("change", update);
    };
    update();
    window.addEventListener("resize", update);
    return () => {
      window.removeEventListener("resize", update);
      query?.removeEventListener("change", update);
    };
  }, []);

  const rowHeight = Math.max(gitGraphRowHeight(fontSize), measuredHeight);
  return useMemo(() => gitGraphPaintMetrics(rowHeight, scale), [rowHeight, scale]);
}
