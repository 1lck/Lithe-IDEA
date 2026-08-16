import { describe, expect, test } from "bun:test";
import type { GitDiffSplitRow } from "../types/git.types";
import { planSplitDiffLayout, resolveDiffViewMode } from "./git-diff-split-layout";

describe("diff view mode", () => {
  test("keeps added and deleted files in a single column", () => {
    expect(resolveDiffViewMode({ is_new: true, is_deleted: false }, "split")).toBe("unified");
    expect(resolveDiffViewMode({ is_new: false, is_deleted: true }, "split")).toBe("unified");
  });

  test("honors the preferred mode for modified files", () => {
    expect(resolveDiffViewMode({ is_new: false, is_deleted: false }, "split")).toBe("split");
    expect(resolveDiffViewMode({ is_new: false, is_deleted: false }, "unified")).toBe("unified");
  });
});

describe("compact split diff layout", () => {
  test("does not advance the empty side for an addition", () => {
    const rows: GitDiffSplitRow[] = [
      {
        kind: "context",
        old_line_number: 1,
        new_line_number: 1,
        old_content: "before",
        new_content: "before",
      },
      { kind: "addition", new_line_number: 2, new_content: "inserted" },
      {
        kind: "context",
        old_line_number: 2,
        new_line_number: 3,
        old_content: "after",
        new_content: "after",
      },
    ];

    const layout = planSplitDiffLayout(rows);

    expect(layout.leftItems.map((item) => [item.rowIndex, item.top])).toEqual([
      [0, 0],
      [2, 1],
    ]);
    expect(layout.rightItems.map((item) => [item.rowIndex, item.top])).toEqual([
      [0, 0],
      [1, 1],
      [2, 2],
    ]);
    expect(layout.transitions).toEqual([
      {
        id: "transition-1",
        kind: "addition",
        leftStart: 1,
        leftEnd: 1,
        rightStart: 1,
        rightEnd: 2,
      },
    ]);
    expect(layout.contentHeight).toBe(3);
  });

  test("does not advance the empty side for a removal", () => {
    const rows: GitDiffSplitRow[] = [
      { kind: "removal", old_line_number: 4, old_content: "removed" },
      {
        kind: "context",
        old_line_number: 5,
        new_line_number: 4,
        old_content: "kept",
        new_content: "kept",
      },
    ];

    const layout = planSplitDiffLayout(rows);

    expect(layout.leftHeight).toBe(2);
    expect(layout.rightHeight).toBe(1);
    expect(layout.transitions[0]).toEqual({
      id: "transition-0",
      kind: "removal",
      leftStart: 0,
      leftEnd: 1,
      rightStart: 0,
      rightEnd: 0,
    });
  });

  test("groups adjacent changed rows into one connector", () => {
    const rows: GitDiffSplitRow[] = [
      {
        kind: "changed",
        old_line_number: 7,
        new_line_number: 7,
        old_content: "old one",
        new_content: "new one",
      },
      {
        kind: "changed",
        old_line_number: 8,
        new_line_number: 8,
        old_content: "old two",
        new_content: "new two",
      },
    ];

    expect(planSplitDiffLayout(rows).transitions).toEqual([
      {
        id: "transition-0",
        kind: "changed",
        leftStart: 0,
        leftEnd: 2,
        rightStart: 0,
        rightEnd: 2,
      },
    ]);
  });
});
