import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const invoke = mock(async (command: string): Promise<unknown> =>
  command === "git_discover_repo" ? "C:/repo" : null,
);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { addWorktreeFromReference } = await import("./git-worktrees-api");

beforeEach(() => {
  invoke.mockReset();
  invoke.mockImplementation(async (command: string) =>
    command === "git_discover_repo" ? "C:/repo" : null,
  );
  emitGitChanged.mockClear();
});

describe("Git reference worktrees", () => {
  test("creates a worktree branch from the selected remote reference and tracks it", async () => {
    await addWorktreeFromReference(
      "C:/repo",
      "D:/worktrees/orders",
      "feature/orders-worktree",
      "refs/remotes/origin/feature/orders",
      "origin/feature/orders",
    );

    expect(invoke).toHaveBeenCalledWith("git.command", {
      repoPath: "C:/repo",
      arguments: [
        "worktree",
        "add",
        "-b",
        "feature/orders-worktree",
        "--",
        "D:/worktrees/orders",
        "refs/remotes/origin/feature/orders",
      ],
    });
    expect(invoke).toHaveBeenCalledWith("git.command", {
      repoPath: "C:/repo",
      arguments: [
        "branch",
        "--set-upstream-to",
        "origin/feature/orders",
        "feature/orders-worktree",
      ],
    });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["repository", "history", "refs"],
      source: "add-reference-worktree",
    });
  });
});
