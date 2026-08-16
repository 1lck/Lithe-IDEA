import { describe, expect, test } from "bun:test";
import { createUntrackedFileDiff } from "./untracked-file-diff";

describe("untracked file diffs", () => {
  test("represents every line in a new text file as an addition", () => {
    const diff = createUntrackedFileDiff("c.txt", "c\ncc\nccc");

    expect({ additions: diff.additions, deletions: diff.deletions }).toEqual({
      additions: 3,
      deletions: 0,
    });
    expect(diff.is_new).toBe(true);
    expect(diff.raw_patch).toBeUndefined();
    expect(diff.lines).toEqual([
      { line_type: "header", content: "@@ -0,0 +1,3 @@" },
      { line_type: "added", content: "c", new_line_number: 1 },
      { line_type: "added", content: "cc", new_line_number: 2 },
      { line_type: "added", content: "ccc", new_line_number: 3 },
    ]);
  });

  test("does not count the trailing newline as an extra added line", () => {
    expect(createUntrackedFileDiff("a.txt", "a\n").additions).toBe(1);
  });
});
