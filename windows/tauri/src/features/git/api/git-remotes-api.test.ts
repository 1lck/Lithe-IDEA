import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";
import type { GitPullPreflight } from "../types/git.types";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");
const getOperationState = mock(async () => null);
const getBranches = mock(async () => []);
const getGitHistory = mock(async () => null);
const getGitStatus = mock(async () => null);

mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("./git-integration-api", () => ({ getOperationState }));
mock.module("./git-branches-api", () => ({ getBranches }));
mock.module("./git-commits-api", () => ({ getGitHistory }));
mock.module("./git-status-api", () => ({ getGitStatus }));

const { executePullChanges, fetchChanges, getGitPullWorkflow, getPullPreflight, pullChanges } =
  await import("./git-remotes-api");

beforeEach(() => {
  invoke.mockReset();
  emitGitChanged.mockClear();
  getBranches.mockClear();
  getGitHistory.mockClear();
  getGitStatus.mockClear();
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
      return null;
    });

    await expect(pullChanges("C:/repo")).resolves.toEqual({
      success: false,
      error: "Branches have diverged. Open Source Control and choose Merge or Rebase.",
    });
    expect(invoke).not.toHaveBeenCalledWith("git_pull", expect.anything());
    expect(getGitStatus).toHaveBeenCalledWith("C:/repo");
    expect(getGitHistory).toHaveBeenCalledWith("C:/repo", 50);
    expect(getBranches).toHaveBeenCalledWith("C:/repo");
    expect(invoke).toHaveBeenCalledWith("git_get_remotes", { repoPath: "C:/repo" });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs", "remotes"],
      source: "pull-finished",
    });
  });
});
