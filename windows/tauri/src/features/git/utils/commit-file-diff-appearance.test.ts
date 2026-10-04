import { expect, test } from "bun:test";
import { commitDiffEditorAppearance } from "./commit-file-diff-appearance";

test("Diff default row spacing scales with font zoom and preserves a custom line height", () => {
  expect(commitDiffEditorAppearance(14, 20).lineHeight).toBe(22);
  expect(commitDiffEditorAppearance(28, 40).lineHeight).toBe(44);
  expect(commitDiffEditorAppearance(14, 30).lineHeight).toBe(30);
  expect(commitDiffEditorAppearance(14, 20).overviewRulerLanes).toBe(0);
  expect(commitDiffEditorAppearance(14, 20).overviewRulerBorder).toBe(false);
  expect(commitDiffEditorAppearance(14, 20).scrollbar).toMatchObject({
    vertical: "visible",
    horizontal: "visible",
    verticalScrollbarSize: 18,
    horizontalScrollbarSize: 18,
    alwaysConsumeMouseWheel: false,
    useShadows: false,
    ignoreHorizontalScrollbarInContentHeight: true,
  });
});
