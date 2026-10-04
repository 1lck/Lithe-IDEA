import type { editor } from "monaco-editor";
import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import { DEFAULT_CODE_FONT_SIZE } from "@/features/settings/config/typography-defaults";

// DiffLayoutMetrics.rowHeight and LitheScrollBarStyle.editorThickness in the macOS reference.
const DIFF_DEFAULT_ROW_HEIGHT = 22;
const DIFF_SCROLLBAR_WIDTH = 18;

export function commitDiffEditorAppearance(fontSize: number, lineHeight: number): editor.IDiffEditorOptions {
  const defaultHeight = Math.ceil(fontSize * EDITOR_CONSTANTS.LINE_HEIGHT_MULTIPLIER);
  return {
    // The Diff has its own change overview; the code-editor ruler otherwise
    // paints an opaque canvas underneath each native scrollbar.
    overviewRulerLanes: 0,
    overviewRulerBorder: false,
    // Respect a custom line height; scale the Diff default with the configured font/zoom.
    lineHeight: lineHeight === defaultHeight
      ? Math.ceil(fontSize * DIFF_DEFAULT_ROW_HEIGHT / DEFAULT_CODE_FONT_SIZE)
      : lineHeight,
    scrollbar: {
      vertical: "visible",
      horizontal: "visible",
      verticalScrollbarSize: DIFF_SCROLLBAR_WIDTH,
      horizontalScrollbarSize: DIFF_SCROLLBAR_WIDTH,
      verticalSliderSize: 12,
      horizontalSliderSize: 12,
      useShadows: false,
      alwaysConsumeMouseWheel: false,
      ignoreHorizontalScrollbarInContentHeight: true,
    },
  };
}
