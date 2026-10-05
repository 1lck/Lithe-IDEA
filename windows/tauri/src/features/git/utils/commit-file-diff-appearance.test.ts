import { expect, test } from "bun:test";
import { commitDiffEditorAppearance } from "./commit-file-diff-appearance";

test("Diff default row spacing scales with font zoom and preserves a custom line height", () => {
  expect(commitDiffEditorAppearance(14, 20).lineHeight).toBe(22);
  expect(commitDiffEditorAppearance(28, 40).lineHeight).toBe(44);
  expect(commitDiffEditorAppearance(14, 30).lineHeight).toBe(30);
  expect(commitDiffEditorAppearance(14, 20).overviewRulerLanes).toBe(0);
  expect(commitDiffEditorAppearance(14, 20).overviewRulerBorder).toBe(false);
  expect(commitDiffEditorAppearance(14, 20).guides).toMatchObject({
    indentation: false,
    bracketPairs: false,
    highlightActiveIndentation: false,
  });
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

test("repository diff leaves five font-scaled rows of bottom space without synthetic text", () => {
  expect(commitDiffEditorAppearance(14, 20).padding).toEqual({ top: 0, bottom: 110 });
  expect(commitDiffEditorAppearance(28, 40).padding?.bottom).toBe(220);
  expect(commitDiffEditorAppearance(14, 30).padding?.bottom).toBe(150);
  expect(commitDiffEditorAppearance(14, 20).scrollBeyondLastLine).toBe(false);
});
