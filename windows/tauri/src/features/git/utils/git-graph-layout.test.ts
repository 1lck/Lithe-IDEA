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

  test("starts a branch tip lane at its node instead of above it", () => {
    // Regression: the newest commit drew a lane segment above its node with nothing above it.
    const layout = layoutGitGraph([
      commit("tip", ["base"], "HEAD -> feature"),
      commit("base", ["root"]),
      commit("side", ["root"], "main"),
      commit("root"),
    ]);

    expect(layout.rows[0].incomingLaneColors[layout.rows[0].lane]).toBeNull();
    expect(layout.rows[1].incomingLaneColors[layout.rows[1].lane]).toBe(layout.rows[1].colorIndex);
    const side = layout.rows[2];
    expect(side.incomingLaneColors[side.lane]).toBeNull();
    // Lanes of other branches passing through the tip row are still drawn.
    expect(side.incomingLaneColors[layout.rows[1].lane]).not.toBeNull();
    // The node keeps its own lane color even though its lane has no incoming segment.
    expect(side.colorIndex).not.toBe(layout.rows[1].colorIndex);
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
