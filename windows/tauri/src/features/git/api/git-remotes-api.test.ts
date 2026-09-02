import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";
import type { GitPullPreflight, GitReference } from "../types/git.types";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  deleteRemoteBranch,
  executePullChanges,
  fetchChanges,
  getGitPullWorkflow,
  getPullPreflight,
  pullChanges,
} = await import("./git-remotes-api");

beforeEach(() => {
  invoke.mockReset();
  emitGitChanged.mockClear();
});

describe("Git remote Pull API", () => {
  test("shares a Pull workflow only within the same repository", () => {
    expect(getGitPullWorkflow("C:/repo")).toBe(getGitPullWorkflow("C:/repo"));
    expect(getGitPullWorkflow("C:/repo")).not.toBe(getGitPullWorkflow("C:/other-repo"));
  });

  test("calls the shared git.pullPreflight contract for the current branch", async () => {
    const preflight: GitPullPreflight = {
      upstream: "origin/main",
      ahead: 1,
      behind: 2,
      diverged: true,
      hasLocalChanges: false,
    };
    invoke.mockImplementation(async (command: string) =>
      command === "git_discover_repo" ? "C:/repo" : preflight,
    );

    await expect(getPullPreflight("C:/repo")).resolves.toEqual(preflight);
    expect(invoke).toHaveBeenCalledWith("git.pullPreflight", { repoPath: "C:/repo" });
  });

  test("executes Pull with only the selected Core mode", async () => {
    invoke.mockImplementation(async (command: string) =>
      command === "git_discover_repo" ? "C:/repo" : null,
    );

    await expect(executePullChanges("C:/repo", "rebase")).resolves.toEqual({ success: true });
    expect(invoke).toHaveBeenCalledWith("git_pull", {
      repoPath: "C:/repo",
      mode: "rebase",
    });
  });

  test("fetches the repository without an ignored remote parameter", async () => {
    invoke.mockImplementation(async (command: string) =>
      command === "git_discover_repo" ? "C:/repo" : null,
    );

    await expect(fetchChanges("C:/repo")).resolves.toEqual({ success: true });
    expect(invoke).toHaveBeenCalledWith("git_fetch", { repoPath: "C:/repo" });
  });

  test("keeps a headless divergent Pull on the safe Cancel default", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      if (command === "git.pullPreflight") {
        return {
          upstream: "origin/main",
          ahead: 1,
          behind: 1,
          diverged: true,
          hasLocalChanges: false,
        } satisfies GitPullPreflight;
      }
      if (command === "git_status") {
        return { repositoryPath: "C:/repo", branch: "main", files: [], ahead: 1, behind: 1 };
      }
      if (command === "git_log") {
        return { references: [], recentReferences: [], commits: [], hasMore: false };
      }
      if (command === "git_branches") return [];
      if (command === "git_get_remotes") return [];
      return null;
    });

    await expect(pullChanges("C:/repo")).resolves.toEqual({
      success: false,
      pullResult: { status: "cancelled" },
    });
    expect(invoke).not.toHaveBeenCalledWith("git_pull", expect.anything());
    expect(invoke).toHaveBeenCalledWith("git_status", { repoPath: "C:/repo" });
    expect(invoke).toHaveBeenCalledWith("git_log", { repoPath: "C:/repo", limit: 50 });
    expect(invoke).toHaveBeenCalledWith("git_branches", { repoPath: "C:/repo" });
    expect(invoke).toHaveBeenCalledWith("git_get_remotes", { repoPath: "C:/repo" });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs", "remotes"],
      source: "pull-finished",
    });
  });

  test("deletes only the selected branch from the selected remote", async () => {
    invoke.mockImplementation(async (command: string) =>
      command === "git_discover_repo" ? "C:/repo" : null,
    );

    const reference: GitReference = {
      fullName: "refs/remotes/team/origin/feature/orders",
      shortName: "team/origin/feature/orders",
      kind: "remote",
      peelsToCommit: true,
      isCurrent: false,
    };
    await deleteRemoteBranch("C:/repo", reference);

    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "deleteRemoteBranch",
      gitReference: {
        fullName: "refs/remotes/team/origin/feature/orders",
        shortName: "team/origin/feature/orders",
        kind: "remote",
      },
    });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["history", "refs", "remotes"],
      source: "delete-remote-branch",
    });
  });
});
