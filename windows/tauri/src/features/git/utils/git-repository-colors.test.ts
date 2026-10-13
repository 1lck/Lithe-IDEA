import { describe, expect, test } from "bun:test";
import {
  GIT_REPOSITORY_COLOR_PALETTE,
  buildGitRepositoryColorMap,
  resolveGitRepositoryColor,
} from "./git-repository-colors";

describe("Git repository colors", () => {
  test("gives each repository a distinct color up to the palette size", () => {
    const repositoryPaths = Array.from(
      { length: GIT_REPOSITORY_COLOR_PALETTE.length },
      (_, index) => `C:/repo-${index}`,
    );
    const colors = buildGitRepositoryColorMap(repositoryPaths);

    expect(colors.size).toBe(GIT_REPOSITORY_COLOR_PALETTE.length);
    expect(new Set(colors.values()).size).toBe(GIT_REPOSITORY_COLOR_PALETTE.length);
    repositoryPaths.forEach((repositoryPath, index) => {
      expect(colors.get(repositoryPath)).toBe(GIT_REPOSITORY_COLOR_PALETTE[index]);
    });
  });

  test("wraps the palette for repositories beyond its length", () => {
    const repositoryPaths = ["C:/a", "C:/b", "C:/c", "C:/d", "C:/e", "C:/f", "C:/g", "C:/h", "C:/i"];
    const colors = buildGitRepositoryColorMap(repositoryPaths);

    expect(colors.get("C:/a")).toBe(colors.get("C:/i"));
    expect(colors.get("C:/a")).toBe(GIT_REPOSITORY_COLOR_PALETTE[0]);
  });

  test("keeps a repository's color stable when a linked worktree is hidden", () => {
    const primary = "C:/workspace/app";
    const worktree = "C:/workspace/app/.worktrees/feature";
    const secondary = "C:/workspace/lib";
    const full = [primary, worktree, secondary];

    // Colors are keyed off the full list, so hiding the worktree must not
    // renumber `secondary` onto the color the worktree used to own.
    expect(resolveGitRepositoryColor(secondary, full)).toBe(GIT_REPOSITORY_COLOR_PALETTE[2]);
    expect(resolveGitRepositoryColor(secondary, [primary, secondary])).toBe(
      GIT_REPOSITORY_COLOR_PALETTE[1],
    );
    expect(buildGitRepositoryColorMap(full).get(secondary)).toBe(
      resolveGitRepositoryColor(secondary, full),
    );
  });

  test("assigns the base color when the workspace has a single repository", () => {
    const colors = buildGitRepositoryColorMap(["C:/only-repo"]);

    expect(colors.size).toBe(1);
    expect(colors.get("C:/only-repo")).toBe(GIT_REPOSITORY_COLOR_PALETTE[0]);
    expect(resolveGitRepositoryColor("C:/only-repo", ["C:/only-repo"])).toBe(
      GIT_REPOSITORY_COLOR_PALETTE[0],
    );
  });

  test("matches repositories by normalized path and falls back for unknown paths", () => {
    const full = ["C:/repo-a", "C:/repo-b"];

    expect(resolveGitRepositoryColor("C:/repo-b/", full)).toBe(GIT_REPOSITORY_COLOR_PALETTE[1]);
    expect(resolveGitRepositoryColor("C:/missing", full)).toBe(GIT_REPOSITORY_COLOR_PALETTE[0]);
  });
});
