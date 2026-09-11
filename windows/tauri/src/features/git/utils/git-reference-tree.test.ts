import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import {
  buildGitReferenceTree,
  collectGitReferenceGroupIds,
  countGitReferencesByKind,
  filterGitLogReferences,
} from "./git-reference-tree";

const reference = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  peelsToCommit: true,
  isCurrent: false,
});

describe("Git reference tree", () => {
  test("groups slash-delimited references without losing leaf references", () => {
    const tree = buildGitReferenceTree(
      [reference("origin/main"), reference("origin/feature/orders")],
      "remote",
    );

    expect(tree).toHaveLength(1);
    expect(tree[0].name).toBe("origin");
    expect(tree[0].children.map((node) => node.name)).toEqual(["feature", "main"]);
    expect(tree[0].children[0].children[0].reference?.shortName).toBe("origin/feature/orders");
    expect(collectGitReferenceGroupIds(tree)).toEqual([
      "remote:origin",
      "remote:origin/feature",
    ]);
  });

  test("counts references instead of top-level namespace nodes", () => {
    const references = [
      reference("origin/main"),
      reference("origin/feature/orders"),
      {
        fullName: "refs/heads/main",
        shortName: "main",
        kind: "local" as const,
        peelsToCommit: true,
        isCurrent: true,
      },
    ];

    expect(buildGitReferenceTree(references, "remote")).toHaveLength(1);
    expect(countGitReferencesByKind(references, "remote")).toBe(2);
    expect(countGitReferencesByKind(references, "local")).toBe(1);
  });

  test("sorts marked local branches before groups and ordinary branches", () => {
    const localReference = (shortName: string): GitReference => ({
      fullName: `refs/heads/${shortName}`,
      shortName,
      kind: "local",
      peelsToCommit: true,
      isCurrent: false,
    });
    const references = [
      localReference("feature/orders"),
      localReference("develop"),
      localReference("main"),
    ];

    const tree = buildGitReferenceTree(references, "local", new Set(["refs/heads/main"]));

    expect(tree.map((node) => node.name)).toEqual(["main", "feature", "develop"]);
  });

  test("shows current, marked, and current-upstream references in my branches mode", () => {
    const references: GitReference[] = [
      {
        fullName: "refs/heads/main",
        shortName: "main",
        kind: "local",
        peelsToCommit: true,
        isCurrent: true,
        upstreamShortName: "origin/main",
      },
      {
        fullName: "refs/heads/feature/orders",
        shortName: "feature/orders",
        kind: "local",
        peelsToCommit: true,
        isCurrent: false,
      },
      {
        fullName: "refs/heads/other",
        shortName: "other",
        kind: "local",
        peelsToCommit: true,
        isCurrent: false,
      },
      reference("origin/main"),
      reference("origin/other"),
      {
        fullName: "refs/tags/v1.0.0",
        shortName: "v1.0.0",
        kind: "tag",
        peelsToCommit: true,
        isCurrent: false,
      },
    ];

    expect(
      filterGitLogReferences(
        references,
        new Set(["refs/heads/feature/orders"]),
        true,
      ).map((item) => item.shortName),
    ).toEqual(["main", "feature/orders", "origin/main"]);
  });
});
