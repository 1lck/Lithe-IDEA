import { describe, expect, test } from "bun:test";
import { tabChromeBuffersEqual, toTabChromeBuffer } from "./tab-chrome-buffer";
import type { DiffContent, EditorContent } from "@/features/panes/types/pane-content.types";

function editorBuffer(overrides: Partial<EditorContent> = {}): EditorContent {
  return {
    id: "buffer-1",
    type: "editor",
    path: "src/main.ts",
    name: "main.ts",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "lots of file text",
    savedContent: "lots of file text",
    isDirty: true,
    isVirtual: false,
    tokens: [{ start: 0, end: 4, token_type: "keyword", class_name: "k" }],
    ...overrides,
  };
}

describe("toTabChromeBuffer", () => {
  test("drops editor content so tab chrome does not rerender on typing", () => {
    const buffer = editorBuffer();

    expect(toTabChromeBuffer(buffer)).toEqual({
      ...buffer,
      content: "",
      savedContent: "",
      tokens: [],
    });
  });

  test("treats content-only updates as equal tab chrome", () => {
    const before = [toTabChromeBuffer(editorBuffer({ content: "a" }))];
    const after = [toTabChromeBuffer(editorBuffer({ content: "ab" }))];
    expect(tabChromeBuffersEqual(before, after)).toBe(true);
  });

  test("rerenders tabs when dirty metadata changes", () => {
    const before = [toTabChromeBuffer(editorBuffer({ isDirty: false }))];
    const after = [toTabChromeBuffer(editorBuffer({ isDirty: true }))];
    expect(tabChromeBuffersEqual(before, after)).toBe(false);
  });

  test("does not throw when comparing against a missing previous snapshot", () => {
    expect(tabChromeBuffersEqual(undefined, [toTabChromeBuffer(editorBuffer())])).toBe(false);
  });

  test("rerenders the reused working-tree diff tab when its title source changes", () => {
    // The commit preview reuses one tab whose title is "Commit: <selected file>".
    const before = [toTabChromeBuffer(workingTreeDiffBuffer("unstaged:src/a.ts"))];
    const sameFile = [toTabChromeBuffer(workingTreeDiffBuffer("unstaged:src/a.ts"))];
    const otherFile = [toTabChromeBuffer(workingTreeDiffBuffer("unstaged:src/b.ts"))];
    const fromGutter = [toTabChromeBuffer(workingTreeDiffBuffer("unstaged:src/a.ts", false))];

    expect(tabChromeBuffersEqual(before, sameFile)).toBe(true);
    expect(tabChromeBuffersEqual(before, otherFile)).toBe(false);
    expect(tabChromeBuffersEqual(before, fromGutter)).toBe(false);
  });

  test("rerenders the reused Git Log preview tab when file arrows select another comparison", () => {
    // "Repository Diff: <file>" reuses one tab at the same virtual path, so the
    // selected diff must participate in tab chrome equality.
    const paths = ["src/a.ts", "src/b.ts"];
    const before = [toTabChromeBuffer(gitLogPreviewBuffer("src/a.ts:0", paths))];
    const sameFile = [toTabChromeBuffer(gitLogPreviewBuffer("src/a.ts:0", paths))];
    const otherFile = [toTabChromeBuffer(gitLogPreviewBuffer("src/b.ts:1", paths))];

    expect(tabChromeBuffersEqual(before, sameFile)).toBe(true);
    expect(tabChromeBuffersEqual(before, otherFile)).toBe(false);
  });
});

function workingTreeDiffBuffer(selectedFileKey: string, commitPreview = true): DiffContent {
  return {
    id: "diff-1",
    type: "diff",
    path: "diff://working-tree/all-files",
    name: "Uncommitted Changes",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "",
    savedContent: "",
    diffData: {
      commitHash: "working-tree",
      files: [],
      totalFiles: 0,
      totalAdditions: 0,
      totalDeletions: 0,
      initiallySelectedFileKey: selectedFileKey,
      commitPreview,
    },
  };
}

/** Git Log reuses `diff://commit-file-preview` while arrows switch the file. */
function gitLogPreviewBuffer(selectedFileKey: string, paths: string[]): DiffContent {
  return {
    id: "diff-2",
    type: "diff",
    path: "diff://commit-file-preview",
    name: "Repository Diff: a.ts",
    isPinned: false,
    isPreview: false,
    isActive: true,
    content: "",
    savedContent: "",
    diffData: {
      commitHash: "abcdef1",
      files: paths.map((filePath) => ({
        file_path: filePath,
        is_new: false,
        is_deleted: false,
        is_renamed: false,
        lines: [],
      })),
      totalFiles: paths.length,
      totalAdditions: 0,
      totalDeletions: 0,
      initiallySelectedFileKey: selectedFileKey,
      initiallyExpandedFileKey: selectedFileKey,
      commitFilePreview: true,
    },
  };
}
