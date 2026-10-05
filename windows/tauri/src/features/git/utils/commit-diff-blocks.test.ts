import { expect, test } from "bun:test";
import { fullDiff } from "@/test-utils/commit-diff-fixtures";
import { planCommitDiffBlocks } from "./commit-diff-blocks";

test("adjacent changes inside one Git context hunk remain separately selectable", () => {
  const head = ["a", "b", "c", "d", "e"];
  const work = ["a", "B", "c", "D", "e"];
  const blocks = planCommitDiffBlocks(fullDiff(head, work), fullDiff(head, head))!;
  expect(blocks).toHaveLength(2);
  expect(blocks.map(block => block.checked)).toEqual([false, false]);
  expect(blocks[1].stage!.lines.filter(line => line.line_type === "added").map(line => line.content)).toEqual(["D"]);
  expect(blocks[1].stage!.lines.filter(line => line.line_type === "context").map(line => line.content)).toContain("b");
});

test("earlier staged additions shift the index span without selecting another block", () => {
  const head = ["a", "b", "c", "d", "e"];
  const index = ["a", "new", "b", "c", "d", "e"];
  const work = ["a", "new", "b", "c", "D", "e"];
  const blocks = planCommitDiffBlocks(fullDiff(head, work), fullDiff(head, index))!;
  expect(blocks.map(block => block.checked)).toEqual([true, false]);
  expect(blocks[1].stage!.lines[0].content).toBe("@@ -2,5 +2,5 @@");
  expect(blocks[1].stage!.lines.filter(line => line.line_type === "added").map(line => line.content)).toEqual(["D"]);
});

test("partly staged lines in one visible block have mixed inclusion and reversible index patches", () => {
  const head = ["a", "b", "c", "d"];
  const blocks = planCommitDiffBlocks(fullDiff(head, ["a", "B", "C", "d"]),
    fullDiff(head, ["a", "B", "c", "d"]))!;
  expect(blocks).toHaveLength(1);
  expect(blocks[0]).toMatchObject({ checked: false, indeterminate: true, canToggle: true, canRollback: true });
  expect(blocks[0].unstage!.lines.filter(line => line.line_type === "removed").map(line => line.content)).toEqual(["b", "c"]);
  expect(blocks[0].rollback!.lines.filter(line => line.line_type === "removed").map(line => line.content)).toEqual(["B", "c"]);
});

test("a staged span crossing a visible block boundary is not silently rewritten", () => {
  const head = ["a", "b", "c", "d", "e"];
  const blocks = planCommitDiffBlocks(fullDiff(head, ["a", "B", "c", "d", "e"]),
    fullDiff(head, ["a", "B", "C", "d", "e"]))!;
  expect(blocks[0].canToggle).toBe(false);
  expect(blocks[0].canRollback).toBe(false);
});

test("an index-only insertion at the outer edge of a visible replacement is preserved", () => {
  const head = ["a", "b", "c"];
  const blocks = planCommitDiffBlocks(fullDiff(head, ["a", "B", "c"]),
    fullDiff(head, ["a", "index only", "b", "c"]))!;
  expect(blocks[0].canToggle).toBe(false);
  expect(blocks[0].canRollback).toBe(false);
});

test("sparse, truncated and mismatched HEAD snapshots cannot produce writable blocks", () => {
  const diff = fullDiff(["a", "b"], ["a", "B"]);
  expect(planCommitDiffBlocks({ ...diff, is_full_context: false }, diff)).toBeNull();
  expect(planCommitDiffBlocks({ ...diff, is_truncated: true }, diff)).toBeNull();
  expect(planCommitDiffBlocks(diff, fullDiff(["wrong", "b"], ["wrong", "B"]))).toBeNull();
});

test("whole-file addition uses one whole-path include action, not an invalid empty-index patch", () => {
  const added = { ...fullDiff([], ["first", "second"]), is_new: true };
  // The fixture helper appends a newline to an empty stream; use Git's real empty-side header.
  added.lines = [{ line_type: "header", content: "@@ -0,0 +1,2 @@" },
    { line_type: "added", content: "first", new_line_number: 1 },
    { line_type: "added", content: "second", new_line_number: 2 }];
  const unchecked = planCommitDiffBlocks(added, { ...added, lines: [] })!;
  expect(unchecked[0]).toMatchObject({ wholeFile: true, canToggle: true, checked: false });
  expect(unchecked[0].stage).toBeUndefined();
  expect(planCommitDiffBlocks(added, added)![0].checked).toBe(true);
});
