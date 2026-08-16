import { describe, expect, test } from "bun:test";
import type { GitCommit } from "../types/git.types";
import { layoutGitGraph, parseGitDecorations } from "./git-graph-layout";

const commit = (
  hash: string,
  parentHashes: string[] = [],
  decorations = "",
): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes,
  message: hash,
  author: "Developer",
  date: "2026/08/16 10:00",
  decorations,
});

describe("Git graph layout", () => {
  test("keeps a linear history in one fixed lane", () => {
    const layout = layoutGitGraph([commit("three", ["two"]), commit("two", ["one"]), commit("one")]);

    expect(layout.laneCount).toBe(1);
    expect(layout.rows.map((row) => row.lane)).toEqual([0, 0, 0]);
    expect(layout.hasMissingParents).toBe(false);
  });

  test("opens a stable secondary lane for a merge parent", () => {
    const layout = layoutGitGraph([
      commit("merge", ["feature", "root"], "HEAD -> main"),
      commit("feature", ["root"], "feature/orders"),
      commit("root"),
    ]);

    expect(layout.rows[0].parentEdges).toHaveLength(2);
    expect(layout.rows[0].parentEdges.map((edge) => edge.targetLane)).toEqual([0, 1]);
    expect(layout.rows[1].parentEdges[0].targetLane).toBe(1);
    expect(layout.rows[2].lane).toBe(1);
    expect(layout.hasMissingParents).toBe(false);
  });

  test("marks parents outside the cumulative snapshot as missing", () => {
    const layout = layoutGitGraph([commit("visible", ["not-loaded"])]);

    expect(layout.hasMissingParents).toBe(true);
    expect(layout.rows[0].parentEdges[0]).toMatchObject({ targetLane: null, isMissing: true });
  });

  test("parses head, branch, remote, and tag decorations", () => {
    expect(parseGitDecorations("HEAD -> main, origin/main, tag: v1.0.0")).toEqual([
      { title: "HEAD", kind: "head" },
      { title: "main", kind: "branch" },
      { title: "origin/main", kind: "remote" },
      { title: "v1.0.0", kind: "tag" },
    ]);
  });
});
