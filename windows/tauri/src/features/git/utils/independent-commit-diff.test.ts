import { expect, test } from "bun:test";
import type { ReviewRow } from "@lithe/editor/diff-review";
import {
  planIndependentCommitDiff,
  commitDiffWordRanges,
  commitDiffScrollAnchors,
  transferCommitDiffLine,
} from "./independent-commit-diff";
const context = (id: number): ReviewRow => ({
  id: String(id),
  left: `line ${id}`,
  right: `line ${id}`,
  oldLine: 100 + id,
  newLine: 200 + id,
  kind: "context",
});

test("independent projections retain history identity and never insert alignment blanks", () => {
  const rows: ReviewRow[] = [
    context(0),
    { id: "remove", left: "old", right: null, oldLine: 101, newLine: null, kind: "removal" },
    ...[1, 2, 3].map((id) => ({
      id: `add${id}`,
      left: null,
      right: `new ${id}`,
      oldLine: null,
      newLine: 200 + id,
      kind: "addition" as const,
    })),
    context(4),
  ];
  const plan = planIndependentCommitDiff(rows, false, new Set());
  expect(plan.left).toHaveLength(3);
  expect(plan.right).toHaveLength(5);
  expect(plan.left[1].oldLine).toBe(101);
  expect(plan.changes).toEqual([
    { leftStart: 1, leftEnd: 2, rightStart: 1, rightEnd: 4, kind: "modified" },
  ]);
});
test("fold expansion restores real rows and preserves change boundaries", () => {
  const rows = Array.from({ length: 1000 }, (_, index) => context(index));
  const plan = planIndependentCommitDiff(rows, true, new Set());
  expect(plan.left).toHaveLength(7);
  expect(plan.left[3].left).toBe("994 hidden lines");
  const expanded = planIndependentCommitDiff(rows, true, new Set([plan.left[3].id]));
  expect(expanded.left).toHaveLength(1000);
  expect(expanded.changes).toEqual([]);
});
test("word highlighting uses exact text offsets and bounds oversized replacement work", () => {
  expect(commitDiffWordRanges("const old = 1;", "const next = 1;")).toEqual({
    left: [[6, 9, "modified"]],
    right: [[6, 10, "modified"]],
  });
  expect(commitDiffWordRanges("x".repeat(9000), "y")).toEqual({ left: [], right: [] });
});

test("synchronized lines clamp unequal replacements and resume matching context in both directions", () => {
  const anchors = commitDiffScrollAnchors(
    [{ leftStart: 5, leftEnd: 6, rightStart: 5, rightEnd: 15, kind: "modified" }],
    36,
    45,
  );
  expect(transferCommitDiffLine(anchors, 1, 5)).toBe(5);
  expect(transferCommitDiffLine(anchors, 1, 10)).toBe(6);
  expect(transferCommitDiffLine(anchors, 1, 15)).toBe(6);
  expect(transferCommitDiffLine(anchors, 1, 16)).toBe(7);
  expect(transferCommitDiffLine(anchors, 0, 6)).toBe(15);
  expect(transferCommitDiffLine(anchors, 0, 37)).toBe(46);
});

test("synchronized insertion and deletion anchors preserve BOF, EOF and zero-width boundaries", () => {
  const anchors = commitDiffScrollAnchors(
    [
      { leftStart: 0, leftEnd: 0, rightStart: 0, rightEnd: 10, kind: "inserted" },
      { leftStart: 10, leftEnd: 15, rightStart: 20, rightEnd: 20, kind: "deleted" },
    ],
    15,
    20,
  );
  expect(transferCommitDiffLine(anchors, 0, 0)).toBe(0);
  expect(transferCommitDiffLine(anchors, 1, 5)).toBe(0);
  expect(transferCommitDiffLine(anchors, 0, 1)).toBe(11);
  expect(transferCommitDiffLine(anchors, 0, 13)).toBe(20);
  expect(transferCommitDiffLine(anchors, 0, 15)).toBe(20);
  expect(transferCommitDiffLine(anchors, 1, 21)).toBe(16);
  expect(transferCommitDiffLine(commitDiffScrollAnchors([], 20, 20), 0, 25)).toBe(25);
});

test("word fragments distinguish replacement blue from pure insertion green and deletion gray", () => {
  expect(commitDiffWordRanges("a b", "a c b")).toEqual({ left: [], right: [[2, 4, "inserted"]] });
  expect(commitDiffWordRanges("a c b", "a b")).toEqual({ left: [[2, 4, "deleted"]], right: [] });
});
