import type { ReviewRow } from "@lithe/editor/diff-review";
import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/editor/diff-review-v1.json";
import type { GitDiff } from "../types/git.types";
import { monacoDiffRows } from "./monaco-diff-rows";

describe("shared Monaco diff rows", () => {
  test("matches the cross-platform sparse patch fixture", () => {
    expect(monacoDiffRows(fixture.gitDiff as GitDiff)).toEqual(fixture.rows as ReviewRow[]);
  });
  test("keeps empty added lines distinct from a missing original side", () => {
    const rows = monacoDiffRows({ ...fixture.gitDiff, lines: [
      { line_type: "added", content: "", new_line_number: 1 },
      { line_type: "added", content: "tail", new_line_number: 2 },
    ] });
    expect(rows.map(row => row.left)).toEqual([null, null]);
    expect(rows.map(row => row.right)).toEqual(["", "tail"]);
    expect(rows.map(row => row.id)).toEqual(["line-0", "line-1"]);
  });
});
