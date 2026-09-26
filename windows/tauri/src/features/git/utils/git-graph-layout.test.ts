import { describe, expect, test } from "bun:test";
import type { GitCommit } from "../types/git.types";
import { graphColorIndexForName, javaStringHashCode } from "./git-graph-colors";
import {
  bestGraphReferenceLabel,
  layoutGitGraph,
  parseGitDecorations,
  type GitGraphLayout,
} from "./git-graph-layout";

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

const colorIndexOfCommit = (layout: GitGraphLayout, hash: string): number | null => {
  const row = layout.rows.find((candidate) => candidate.commit.hash === hash);
  if (!row) throw new Error(`No graph row for ${hash}`);
  return row.incomingLaneColors[row.lane] ?? row.parentEdges[0]?.colorIndex ?? null;
};

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

  test("keeps a branch color stable when the topology moves it to another lane", () => {
    const featureTipInFirstLane = layoutGitGraph([
      commit("tip", ["root"], "feature/orders"),
      commit("root"),
    ]);
    const featureAsSecondParent = layoutGitGraph([
      commit("merge", ["root", "tip"], "HEAD -> main"),
      commit("tip", ["root"], "feature/orders"),
      commit("root"),
    ]);

    expect(colorIndexOfCommit(featureTipInFirstLane, "tip")).toBe(
      graphColorIndexForName("feature/orders"),
    );
    expect(colorIndexOfCommit(featureAsSecondParent, "tip")).toBe(
      graphColorIndexForName("feature/orders"),
    );
    expect(featureAsSecondParent.rows[1].lane).toBe(1);
    expect(colorIndexOfCommit(featureAsSecondParent, "merge")).toBe(
      graphColorIndexForName("main"),
    );
  });

  test("gives unreferenced lanes a deterministic color", () => {
    const commits = [commit("a", ["b", "c"]), commit("b", ["d"]), commit("c", ["d"]), commit("d")];
    const first = layoutGitGraph(commits);
    const second = layoutGitGraph(commits);

    expect(colorIndexOfCommit(first, "a")).toBe(0);
    expect(colorIndexOfCommit(first, "c")).toBe(1);
    expect(first.rows.map((row) => row.incomingLaneColors)).toEqual(
      second.rows.map((row) => row.incomingLaneColors),
    );
  });

  test("maps reference names through Java String.hashCode", () => {
    expect(javaStringHashCode("main")).toBe(3343801);
    expect(graphColorIndexForName("main")).toBe(1);
    expect(graphColorIndexForName("feature/orders")).toBe(4);
  });

  test("prefers the most significant reference for the color identity", () => {
    expect(bestGraphReferenceLabel(parseGitDecorations("HEAD -> main, origin/main, tag: v1")))
      .toMatchObject({ title: "origin/main" });
    expect(bestGraphReferenceLabel(parseGitDecorations("HEAD -> feature/orders, hotfix")))
      .toMatchObject({ title: "feature/orders" });
    expect(bestGraphReferenceLabel([])).toBeNull();
  });
});
