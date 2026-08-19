import { describe, expect, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import { buildGitReferenceTree } from "./git-reference-tree";

const reference = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
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
});
