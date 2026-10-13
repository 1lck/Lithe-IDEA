import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { GitPullWorkflow } from "../hooks/git-pull-workflow";
import type { GitReference, GitWorktree, PullStrategy } from "../types/git.types";
import { updateGitLogBranch } from "./git-log-branch-update";

const branches = await import("../api/git-branches-api");
const remotes = await import("../api/git-remotes-api");
const worktrees = await import("../api/git-worktrees-api");
const dialogs = await import("./git-pull-dialog-service");
const events = await import("../events/git-events");
const spies: Array<{ mockRestore: () => void }> = [];
let entries: GitWorktree[];
let diverged: boolean;
let hasLocalChanges: boolean;
const calls: string[] = [];
const refresh = mock(async () => {});
const readWorktrees = mock(async (repoPath: string) => entries.map((entry) => ({
  ...entry, is_current: entry.path === repoPath,
})));
const updateBranch = mock(async (_repoPath: string, _reference: GitReference) => {});
const showPull = mock(async () => ({ status: "cancelled" as const }));
const reference: GitReference = {
  fullName: "refs/heads/topic",
  shortName: "topic",
  kind: "local",
  isCurrent: false,
  peelsToCommit: true,
  upstreamShortName: "origin/topic",
  behind: 0,
};
const tree = (path: string, is_current: boolean): GitWorktree => ({
  path,
  is_current,
  branch: "topic",
  head: "a".repeat(40),
  is_bare: false,
  is_detached: false,
});

beforeEach(() => {
  entries = [];
  diverged = false;
  hasLocalChanges = false;
  calls.length = 0;
  refresh.mockClear();
  updateBranch.mockClear();
  showPull.mockClear();
  readWorktrees.mockClear();
  spies.push(
    spyOn(worktrees, "readWorktrees").mockImplementation(readWorktrees),
    spyOn(branches, "updateBranch").mockImplementation(updateBranch),
    spyOn(dialogs, "showGitPullDialog").mockImplementation(showPull),
    spyOn(events, "emitGitChanged").mockImplementation(() => {}),
    spyOn(remotes, "getGitPullWorkflow").mockImplementation(
      () =>
        new GitPullWorkflow({
          fetch: async (path) => {
            calls.push(`fetch:${path}`);
            return { success: true };
          },
          preflight: async (path) => {
            calls.push(`preflight:${path}`);
            return {
              upstream: "origin/topic",
              ahead: diverged ? 1 : 0,
              behind: 2,
              diverged,
              hasLocalChanges,
            };
          },
          pull: async (path, strategy: PullStrategy, _reference, expectedBranch) => {
            expect(expectedBranch).toBe(reference.fullName);
            calls.push(`pull:${path}:${strategy}`);
            return { success: true };
          },
          operationState: async () => null,
        }),
    ),
  );
});
afterEach(() => {
  for (const spy of spies.splice(0)) spy.mockRestore();
});

test("Current selected branch updates in the background with the existing Merge default", async () => {
  entries = [tree("C:/repo", true)];
  diverged = true;
  await expect(
    updateGitLogBranch("C:/repo", { ...reference, isCurrent: true }, refresh),
  ).resolves.toEqual({ status: "pulled", strategy: "merge" });
  expect(calls).toEqual(["fetch:C:/repo", "preflight:C:/repo", "pull:C:/repo:merge"]);
  expect(showPull).not.toHaveBeenCalled();
  expect(updateBranch).not.toHaveBeenCalled();
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("Uncheckout branch updates its full reference even when cached behind is zero", async () => {
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
    status: "branch-updated",
  });
  expect(updateBranch.mock.calls).toEqual([["C:/repo", reference]]);
  expect(calls).toEqual([]);
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("Branch in another worktree fast-forwards there without switching the active repository", async () => {
  entries = [tree("C:/worktree", false)];
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
    status: "pulled",
    strategy: "ffOnly",
  });
  expect(calls).toEqual(["fetch:C:/worktree", "preflight:C:/worktree", "pull:C:/worktree:ffOnly"]);
  expect(updateBranch).not.toHaveBeenCalled();
  expect(events.emitGitChanged).toHaveBeenCalledWith({
    repoPath: "C:/repo",
    scopes: ["history", "refs", "remotes"],
    source: "update-branch",
  });
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("Diverged other worktree fails without requesting an invisible strategy dialog", async () => {
  entries = [tree("C:/worktree", false)];
  diverged = true;
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toMatchObject({
    status: "failed",
    stage: "pull",
  });
  expect(calls).toEqual(["fetch:C:/worktree", "preflight:C:/worktree"]);
  expect(showPull).not.toHaveBeenCalled();
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("Dirty checked-out worktree keeps changes and does not start Pull", async () => {
  entries = [tree("C:/worktree", false)];
  hasLocalChanges = true;
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
    status: "blocked",
    reason: "dirty",
  });
  expect(calls).toEqual(["fetch:C:/worktree", "preflight:C:/worktree"]);
});

test("Current worktree is resolved from fresh metadata rather than the stale isCurrent flag", async () => {
  entries = [tree("C:/repo", true)];
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
    status: "pulled",
    strategy: "merge",
  });
});

test("Invalid targets and failed worktree inspection never start a write", async () => {
  await expect(
    updateGitLogBranch("C:/repo", { ...reference, kind: "remote" }, refresh),
  ).rejects.toThrow();
  await expect(
    updateGitLogBranch("C:/repo", { ...reference, upstreamShortName: undefined }, refresh),
  ).rejects.toThrow();
  readWorktrees.mockImplementationOnce(async () => {
    throw new Error("cannot inspect worktrees");
  });
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).rejects.toThrow(
    "cannot inspect worktrees",
  );
  expect(updateBranch).not.toHaveBeenCalled();
  expect(calls).toEqual([]);
});

test("Failed direct update still refreshes without reporting success", async () => {
  updateBranch.mockImplementationOnce(async () => {
    throw new Error("non-fast-forward");
  });
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).rejects.toThrow(
    "non-fast-forward",
  );
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("A Log that changes scope during worktree discovery never starts a write", async () => {
  await expect(updateGitLogBranch("C:/repo", reference, refresh, () => false)).resolves.toEqual({
    status: "cancelled",
  });
  expect(updateBranch).not.toHaveBeenCalled();
  expect(calls).toEqual([]);
  expect(refresh).not.toHaveBeenCalled();
});

for (const changeAt of ["fetch", "preflight"] as const) {
  test(`A checkout changed during ${changeAt} cannot update the replacement branch`, async () => {
    entries = [tree("C:/worktree", false)];
    const pull = mock(async () => ({ success: true }));
    const changeBranch = () => { entries = [{ ...tree("C:/worktree", false), branch: "other" }]; };
    // The workflow pauses at deterministic dependency boundaries, not a timer.
    spies.push(spyOn(remotes, "getGitPullWorkflow").mockImplementation(() => new GitPullWorkflow({
      fetch: async () => { if (changeAt === "fetch") changeBranch(); return { success: true }; },
      preflight: async () => {
        if (changeAt === "preflight") changeBranch();
        return { upstream: "origin/other", ahead: 0, behind: 2, diverged: false, hasLocalChanges: false };
      },
      pull, operationState: async () => null,
    })));
    await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
      status: "blocked", reason: "state-changed",
    });
    expect(pull).not.toHaveBeenCalled(); expect(updateBranch).not.toHaveBeenCalled();
    expect(refresh).toHaveBeenCalledTimes(1);
  });
}

test("A detached target worktree also blocks the selected-branch update", async () => {
  entries = [tree("C:/worktree", false)];
  readWorktrees.mockImplementationOnce(async () => entries)
    .mockImplementationOnce(async () => [{ ...tree("C:/worktree", true), is_detached: true }]);
  await expect(updateGitLogBranch("C:/repo", reference, refresh)).resolves.toEqual({
    status: "blocked", reason: "state-changed",
  });
  expect(calls).toEqual(["fetch:C:/worktree"]);
});