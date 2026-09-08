import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const invoke = mock(
  async (command: string): Promise<unknown> => (command === "git_discover_repo" ? "C:/repo" : null),
);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { addWorktreeFromReference, createWorktree, removeWorktree } =
  await import("./git-worktrees-api");

beforeEach(() => {
  invoke.mockReset();
  invoke.mockImplementation(async (command: string) =>
    command === "git_discover_repo" ? "C:/repo" : null,
  );
  emitGitChanged.mockClear();
});

afterAll(() => emitGitChanged.mockRestore());

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

test("existing and detached worktrees preserve independent noCheckout without synthesizing a branch", async () => {
  await createWorktree("C:/repo", {
    destination: "D:/linked",
    worktreeMode: "existingBranch",
    noCheckout: true,
    reference: {
      fullName: "refs/heads/topic",
      shortName: "topic",
      kind: "local",
      isCurrent: false,
      peelsToCommit: true,
    },
  });
  expect(invoke).toHaveBeenLastCalledWith("git.write", {
    root: "C:/repo",
    operation: "createWorktree",
    destination: "D:/linked",
    worktreeMode: "existingBranch",
    noCheckout: true,
    gitReference: { fullName: "refs/heads/topic", shortName: "topic", kind: "local" },
  });
  await createWorktree("C:/repo", {
    destination: "D:/detached",
    worktreeMode: "detached",
    noCheckout: false,
    revision: "reviewed-commit",
  });
  expect(invoke).toHaveBeenLastCalledWith("git.write", {
    root: "C:/repo",
    operation: "createWorktree",
    destination: "D:/detached",
    worktreeMode: "detached",
    noCheckout: false,
    revision: "reviewed-commit",
  });
});

test("worktree removal uses Core protections and propagates refusal", async () => {
  invoke.mockImplementation(async (command: string) => {
    if (command === "git_discover_repo") return "C:/repo";
    if (command === "git.write") throw new Error("Worktree contains changes");
    return null;
  });
  await expect(removeWorktree("C:/repo", "D:/linked")).rejects.toThrow("Worktree contains changes");
  expect(invoke).toHaveBeenLastCalledWith("git.write", {
    root: "C:/repo",
    operation: "removeWorktree",
    destination: "D:/linked",
    force: false,
  });
});
