import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import { buildGitReferenceTree, countGitReferencesByKind } from "./git-reference-tree";

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
  });

  test("counts references instead of top-level namespace nodes", () => {
    const references = [
      reference("origin/main"),
      reference("origin/feature/orders"),
      {
        fullName: "refs/heads/main",
        shortName: "main",
        kind: "local" as const,
        isCurrent: true,
      },
    ];

    expect(buildGitReferenceTree(references, "remote")).toHaveLength(1);
    expect(countGitReferencesByKind(references, "remote")).toBe(2);
    expect(countGitReferencesByKind(references, "local")).toBe(1);
  });
});
