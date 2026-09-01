import { describe, expect, test } from "bun:test";
import {
  isContiguousGitHistorySelection,
  resolveGitHistoryContextSelection,
  selectedCommitsInHistoryOrder,
  updateGitHistorySelection,
} from "./git-history-selection";

const hashes = ["d", "c", "b", "a"];

describe("Git history selection", () => {
  test("supports replacement, additive, and contiguous range selection", () => {
    expect(
      updateGitHistorySelection(hashes, new Set(["a"]), "c", "a", {
        additive: false,
        range: false,
      }),
    ).toEqual({ selected: new Set(["c"]), anchor: "c" });

    expect(
      updateGitHistorySelection(hashes, new Set(["c"]), "b", "c", {
        additive: true,
        range: false,
      }).selected,
    ).toEqual(new Set(["c", "b"]));

    expect(
      updateGitHistorySelection(hashes, new Set(), "a", "c", {
        additive: false,
        range: true,
      }).selected,
    ).toEqual(new Set(["c", "b", "a"]));
  });

  test("right-click preserves only an existing row selection", () => {
    const selected = new Set(["c", "b"]);
    expect(resolveGitHistoryContextSelection(selected, "b")).toEqual(selected);
    expect(resolveGitHistoryContextSelection(selected, "a")).toEqual(new Set(["a"]));
  });

  test("orders selected commits and detects gaps in the complete history", () => {
    const commits = hashes.map((hash, index) => ({
      hash,
      parentHashes: hashes[index + 1] ? [hashes[index + 1]] : [],
      decorations: index === 0 ? "HEAD -> main" : "",
    }));
    expect(selectedCommitsInHistoryOrder(commits, new Set(["b", "d"]))).toEqual([
      commits[0],
      commits[2],
    ]);
    expect(isContiguousGitHistorySelection(commits, new Set(["c", "b"]))).toBe(true);
    expect(isContiguousGitHistorySelection(commits, new Set(["d", "b"]))).toBe(false);
  });
});
