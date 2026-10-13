import { describe, expect, test } from "bun:test";
import {
  isLinkedWorktreeRepository,
  resolveVisibleRepositoryPaths,
} from "./git-workspace-repositories";

describe("Linked worktree repository detection", () => {
  test("classifies repositories nested inside another repository as worktrees", () => {
    const paths = [
      "D:/workspace/work-code/op/op-platform",
      "D:/workspace/work-code/op/op-platform/.worktrees/apps-sealed",
      "D:/workspace/work-code/op/op-platform-extra",
    ];

    expect(
      isLinkedWorktreeRepository(
        "D:/workspace/work-code/op/op-platform/.worktrees/apps-sealed",
        paths,
      ),
    ).toBe(true);
    expect(isLinkedWorktreeRepository("D:/workspace/work-code/op/op-platform", paths)).toBe(false);
    expect(isLinkedWorktreeRepository("D:/workspace/work-code/op/op-platform-extra", paths)).toBe(
      false,
    );
  });

  test("does not treat a sibling with a shared name prefix as nested", () => {
    expect(isLinkedWorktreeRepository("C:/repo-a-extra", ["C:/repo-a", "C:/repo-a-extra"])).toBe(
      false,
    );
  });

  test("is order-independent and ignores duplicate paths", () => {
    const worktree = "C:/root/primary/.worktrees/feature";
    expect(isLinkedWorktreeRepository(worktree, [worktree, "C:/root/primary"])).toBe(true);
    expect(isLinkedWorktreeRepository(worktree, ["C:/root/primary", worktree])).toBe(true);
    expect(isLinkedWorktreeRepository("C:/root/primary", ["C:/root/primary", "C:/root/primary"])).toBe(
      false,
    );
  });
});

describe("Visible repository selection", () => {
  const primary = "C:/root/op-platform";
  const worktree = "C:/root/op-platform/.worktrees/apps-sealed";
  const paths = [primary, worktree];

  test("keeps every repository while worktree repositories are shown", () => {
    expect(resolveVisibleRepositoryPaths(paths, primary, true)).toEqual(paths);
  });

  test("drops nested repositories and keeps the active one when hidden", () => {
    expect(resolveVisibleRepositoryPaths(paths, primary, false)).toEqual([primary]);
    expect(resolveVisibleRepositoryPaths(paths, worktree, false)).toEqual(paths);
  });

  test("leaves single-repository workspaces unchanged", () => {
    expect(resolveVisibleRepositoryPaths([primary], primary, false)).toEqual([primary]);
  });
});
