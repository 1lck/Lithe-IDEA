import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const emitGitChanged = spyOn(gitEvents, "emitGitChanged");
let rejectApply = false;
const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.patchApply") {
    if (rejectApply) throw new Error("Repository changed after preview");
    return { exitCode: 0, output: "", warnings: [] };
  }
  return { patch: "", files: [], byteLength: 0 };
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
const { applyGitPatch, exportGitPatch } = await import("./git-patch-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  rejectApply = false;
});
afterAll(() => emitGitChanged.mockRestore());

describe("Git patch exchange boundary", () => {
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
