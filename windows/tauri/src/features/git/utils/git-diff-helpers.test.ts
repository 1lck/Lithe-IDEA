import { describe, expect, test } from "bun:test";
import type { DiffLineWithIndex } from "../types/git-diff.types";
import {
  countSplitDiffStats,
  createFallbackSplitRows,
  hasInvisibleDiffChanges,
} from "./git-diff-helpers";

describe("split diff fallback alignment", () => {
  test("pairs removals and additions into shared visual rows", () => {
    const lines: DiffLineWithIndex[] = [
      {
        line_type: "context",
        content: "a",
        old_line_number: 1,
        new_line_number: 1,
        diffIndex: 1,
      },
      {
        line_type: "removed",
        content: "aa",
        old_line_number: 2,
        diffIndex: 2,
      },
      {
        line_type: "added",
        content: "aa",
        new_line_number: 2,
        diffIndex: 3,
      },
      {
        line_type: "added",
        content: "abc",
        new_line_number: 3,
        diffIndex: 4,
      },
    ];

    const rows = createFallbackSplitRows(lines);
    expect(rows).toEqual([
      {
        kind: "context",
        old_line_number: 1,
        new_line_number: 1,
        old_content: "a",
        new_content: "a",
      },
      {
        kind: "context",
        old_line_number: 2,
        new_line_number: 2,
        old_content: "aa",
        new_content: "aa",
      },
      {
        kind: "addition",
        old_line_number: undefined,
        new_line_number: 3,
        old_content: undefined,
        new_content: "abc",
      },
    ]);
    expect(countSplitDiffStats([rows])).toEqual({ additions: 1, deletions: 0 });
  });
});

describe("invisible diff changes", () => {
  test("detects rows that only differ in line termination", () => {
    expect(
      hasInvisibleDiffChanges([
        {
          kind: "context",
          old_line_number: 1,
          new_line_number: 1,
          old_content: "same",
          new_content: "same",
          is_invisible_change: true,
        },
      ]),
    ).toBe(true);
    expect(
      hasInvisibleDiffChanges([
        {
          kind: "changed",
          old_content: "before",
          new_content: "after",
        },
      ]),
    ).toBe(false);
  });
});
