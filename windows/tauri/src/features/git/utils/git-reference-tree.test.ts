import { describe, expect, mock, test } from "bun:test";
import type { GitReference } from "../types/git.types";
import * as tauriCoreModule from "@/platform/tauri-core";

const invoke = mock(async (_command: string, args: { references: { name: string }[] }) => {
  // Stands in for Core: shared/fixtures/git/reference-tree-v1.json owns the grouping rules.
  const [first] = args.references;
  return {
    nodes: [
      {
        name: "origin",
        path: "origin",
        reference: null,
        children: args.references.map((item, index) => ({
          name: item.name.slice("origin/".length),
          path: item.name,
          reference: index,
          children: [],
        })),
      },
    ].filter(() => first),
  };
});
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

const {
  loadGitReferenceTree,
  collectGitReferenceGroupIds,
  countGitReferencesByKind,
  filterGitLogReferences,
  filterSelectableGitReferences,
  isRemoteSymbolicHeadReference,
} = await import("./git-reference-tree");

const reference = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  peelsToCommit: true,
  isCurrent: false,
});

describe("Git reference tree", () => {
  test("attaches loaded references and row identities to the Core plan", async () => {
    const tree = await loadGitReferenceTree(
      [reference("origin/main"), reference("origin/orders")],
      "remote",
      new Set(),
      "A:",
    );

    expect(invoke).toHaveBeenCalledWith("git.referenceTree", {
      references: [{ name: "origin/main" }, { name: "origin/orders" }],
    });
    expect(tree[0].id).toBe("A:remote:origin");
    expect(tree[0].children[1].reference?.shortName).toBe("origin/orders");
    expect(collectGitReferenceGroupIds(tree)).toEqual(["A:remote:origin"]);
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

    expect(countGitReferencesByKind(references, "remote")).toBe(2);
    expect(countGitReferencesByKind(references, "local")).toBe(1);
  });

  test("sends marked local branches as prioritized references", async () => {
    const local = (shortName: string): GitReference => ({
      fullName: `refs/heads/${shortName}`,
      shortName,
      kind: "local",
      peelsToCommit: true,
      isCurrent: false,
    });
    await loadGitReferenceTree(
      [local("develop"), local("main")],
      "local",
      new Set(["refs/heads/main"]),
    );

    expect(invoke).toHaveBeenLastCalledWith("git.referenceTree", {
      references: [{ name: "develop" }, { name: "main", prioritized: true }],
    });
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

describe("remote symbolic HEAD references", () => {
  test("treats refs/remotes/<remote>/HEAD as a symbolic alias, not a branch", () => {
    expect(isRemoteSymbolicHeadReference(reference("origin/HEAD"))).toBe(true);
    expect(isRemoteSymbolicHeadReference(reference("upstream/HEAD"))).toBe(true);
    expect(isRemoteSymbolicHeadReference(reference("origin/main"))).toBe(false);
    expect(
      isRemoteSymbolicHeadReference({
        fullName: "refs/heads/HEAD",
        shortName: "HEAD",
        kind: "local",
        peelsToCommit: true,
        isCurrent: false,
      }),
    ).toBe(false);
  });

  test("hides remote HEAD aliases while keeping every real reference", () => {
    const references = [
      reference("origin/HEAD"),
      reference("origin/main"),
      reference("origin/release"),
      { ...reference("upstream/HEAD") },
    ];

    expect(filterSelectableGitReferences(references).map((item) => item.shortName)).toEqual([
      "origin/main",
      "origin/release",
    ]);
  });
});
