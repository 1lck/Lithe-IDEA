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
  const reference = {
    fullName: "refs/remotes/origin/feature/orders",
    shortName: "origin/feature/orders",
    kind: "remote" as const,
    peelsToCommit: true,
    isCurrent: false,
  };

  test("creates a worktree branch from the selected remote reference and tracks it", async () => {
    await addWorktreeFromReference(
      "C:/repo",
      "D:/worktrees/orders",
      "feature/orders-worktree",
      reference,
    );

    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "createWorktree",
      destination: "D:/worktrees/orders",
      name: "feature/orders-worktree",
      gitReference: {
        fullName: "refs/remotes/origin/feature/orders",
        shortName: "origin/feature/orders",
        kind: "remote",
      },
    });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["repository", "history", "refs"],
      source: "add-reference-worktree",
    });
  });

  test("refreshes repository state when atomic worktree creation fails", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      if (command === "git.write") throw new Error("worktree creation failed");
      return null;
    });

    await expect(
      addWorktreeFromReference(
        "C:/repo",
        "D:/worktrees/orders",
        "feature/orders-worktree",
        reference,
      ),
    ).rejects.toThrow("worktree creation failed");
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["repository", "history", "refs"],
      source: "add-reference-worktree",
    });
  });
});
