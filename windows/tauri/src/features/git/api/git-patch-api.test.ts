import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";
import patchFixture from "../../../../../../shared/fixtures/git/patch-exchange-v1.json";

const emitGitChanged = spyOn(gitEvents, "emitGitChanged");
let rejectApply = false;
let checkResult: { exitCode: number; operationError?: { message: string } };
let rejectCheck = false;
const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.patchApply") {
    if (rejectApply) throw new Error("Repository changed after preview");
    return { exitCode: 0, output: "", warnings: [] };
  }
  if (command === "git.apply") {
    if (rejectCheck) throw new Error("Native check unavailable");
    return checkResult;
  }
  return { patch: "", files: [], byteLength: 0 };
});
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));
const { applyGitPatch, exportGitPatch, isGitPatchApplied } = await import("./git-patch-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  rejectApply = false;
  checkResult = { exitCode: 0 };
  rejectCheck = false;
});

for (const [target, mode] of [
  ["indexAndWorktree", "restoreIndexCheck"],
  ["worktree", "worktreeCheck"],
] as const) {
  test(`checks already-restored ${target} patches through the existing read-only Core mode`, async () => {
    expect(await isGitPatchApplied("C:/repo", "saved patch", target)).toBe(true);
    expect(invoke).toHaveBeenLastCalledWith("git.apply", {
      root: "C:/repo",
      patch: "saved patch",
      mode,
    });
    expect(emitGitChanged).not.toHaveBeenCalled();
  });
}

test("an unsuccessful or unavailable native check never confirms an already-applied patch", async () => {
  checkResult = { exitCode: 1 };
  expect(await isGitPatchApplied("C:/repo", "saved patch", "worktree")).toBe(false);
  checkResult = { exitCode: 0, operationError: { message: "check failed" } };
  expect(await isGitPatchApplied("C:/repo", "saved patch", "worktree")).toBe(false);
  rejectCheck = true;
  await expect(isGitPatchApplied("C:/repo", "saved patch", "worktree")).rejects.toThrow(
    "Native check unavailable",
  );
});
afterAll(() => emitGitChanged.mockRestore());

describe("Git patch exchange boundary", () => {
  test("exports the complete Shelf working layer relative to the real index", async () => {
    const { source, paths, includeUntracked } = patchFixture.unstagedWithUntrackedRequest;
    await exportGitPatch("C:/repo", source as "unstaged", paths, { includeUntracked });
    expect(invoke).toHaveBeenLastCalledWith("git.patchExport", {
      ...patchFixture.unstagedWithUntrackedRequest,
      root: "C:/repo",
    });
  });

  test("keeps the selected base-to-target direction and selected file paths", async () => {
    await exportGitPatch("C:/repo", "commits", ["folder/example.txt"], {
      baseRevision: "before",
      targetRevision: "after",
    });
    expect(invoke).toHaveBeenLastCalledWith("git.patchExport", {
      root: "C:/repo",
      source: "commits",
      paths: ["folder/example.txt"],
      baseRevision: "before",
      targetRevision: "after",
    });
  });

  test("applies the unchanged reviewed patch with its expected state and preserves rejection refresh", async () => {
    const patch =
      "diff --git a/a.txt b/a.txt\r\n--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n";
    rejectApply = true;
    await expect(
      applyGitPatch("C:/repo", patch, "indexAndWorktree", "reviewed-state"),
    ).rejects.toThrow("Repository changed after preview");
    expect(invoke).toHaveBeenLastCalledWith("git.patchApply", {
      root: "C:/repo",
      patch,
      target: "indexAndWorktree",
      expectedState: "reviewed-state",
    });
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree"],
      source: "apply-patch",
    });
  });
});

test("file discovery requests metadata independently of patch text generation", async () => {
  await exportGitPatch("C:/repo", "workingTree", [], {}, "discover", true);
  expect(invoke).toHaveBeenLastCalledWith("git.patchExport", {
    root: "C:/repo",
    source: "workingTree",
    paths: [],
    operationId: "discover",
    metadataOnly: true,
  });
});
