import { describe, expect, mock, test } from "bun:test";
import type { GitDiff, GitHunk } from "../types/git.types";
import { createMonacoDiffHunkActions, workingTreeStagingContext } from "./monaco-diff-hunk-actions";
import { monacoDiffRows } from "./monaco-diff-rows";

const diff: GitDiff = {
  file_path: "src/Sample.java", is_new: false, is_deleted: false, is_renamed: false,
  lines: [
    { line_type: "header", content: "@@ -91,2 +91,2 @@" },
    { line_type: "removed", content: "oldValue", old_line_number: 91 },
    { line_type: "added", content: "newValue", new_line_number: 91 },
    { line_type: "context", content: "", old_line_number: 92, new_line_number: 92 },
    { line_type: "header", content: "@@ -501,2 +501,2 @@" },
    { line_type: "context", content: "  // 尾部", old_line_number: 501, new_line_number: 501 },
    { line_type: "removed", content: "oldTail", old_line_number: 502 },
    { line_type: "added", content: "newTail", new_line_number: 502 },
  ],
};
const context = { repoPath: "C:/workspace/nested-repo", isStaged: false };
function operations() {
  return {
    stage: mock(async (_repo: string, _hunk: GitHunk) => true),
    unstage: mock(async (_repo: string, _hunk: GitHunk) => true),
  };
}
function deferred() {
  let resolve!: (value: boolean) => void;
  const promise = new Promise<boolean>(accept => { resolve = accept; });
  return { promise, resolve };
}

describe("Windows Monaco diff hunk actions", () => {
  test("only enables identified working-tree sections in their owning repository", () => {
    const review = { commitHash: "working-tree", repoPath: context.repoPath };
    expect(workingTreeStagingContext(review, "unstaged:src/Sample.java")).toEqual(context);
    expect(workingTreeStagingContext(review, "staged:src/Sample.java"))
      .toEqual({ ...context, isStaged: true });
    expect(workingTreeStagingContext({ ...review, commitHash: "a".repeat(40) }, "unstaged:src/Sample.java"))
      .toBeUndefined();
    expect(workingTreeStagingContext({ commitHash: "working-tree" }, "unstaged:src/Sample.java"))
      .toBeUndefined();
    expect(workingTreeStagingContext(review, "src/Sample.java:0")).toBeUndefined();
  });

  for (const isStaged of [false, true]) {
    const action = isStaged ? "unstage" : "stage";
    test(`routes ${action} to the original sparse hunk and explicit repository`, async () => {
      const api = operations();
      const owner = createMonacoDiffHunkActions(diff, { ...context, isStaged }, api);
      const other = isStaged ? "stage" : "unstage";
      const header = monacoDiffRows(diff).filter(row => row.kind === "information")[1];
      expect(owner.action).toBe(action);
      expect(await owner.apply(header.hunkID!, action)).toBe("applied");
      expect(api[action]).toHaveBeenCalledWith(context.repoPath, {
        file_path: "src/Sample.java", lines: diff.lines.slice(4),
      });
      expect(api[other]).not.toHaveBeenCalled();
      owner.dispose();
    });
  }

  test("rejects repeated clicks while pending and until a successful patch is refreshed", async () => {
    const api = operations();
    const pending = deferred();
    api.stage.mockImplementationOnce(() => pending.promise);
    const owner = createMonacoDiffHunkActions(diff, context, api);
    const first = owner.apply("hunk-0", "stage");
    expect(api.stage).toHaveBeenCalledTimes(1);
    expect(await owner.apply("hunk-4", "stage")).toBe("ignored");
    pending.resolve(true);
    expect(await first).toBe("applied");
    expect(await owner.apply("hunk-4", "stage")).toBe("ignored");
    expect(api.stage).toHaveBeenCalledTimes(1);
    owner.dispose();

    const refreshed = createMonacoDiffHunkActions({ ...diff, lines: diff.lines.slice(4) }, context, api);
    expect(await refreshed.apply("hunk-0", "stage")).toBe("applied");
    expect(api.stage).toHaveBeenLastCalledWith(context.repoPath, {
      file_path: diff.file_path, lines: diff.lines.slice(4),
    });
    refreshed.dispose();
  });

  test("reports a failed Git write and permits retry without an unhandled rejection", async () => {
    const api = operations();
    api.stage.mockResolvedValueOnce(false).mockRejectedValueOnce(new Error("Git rejected patch"));
    const owner = createMonacoDiffHunkActions(diff, context, api);
    expect(await owner.apply("hunk-0", "stage")).toBe("failed");
    expect(await owner.apply("hunk-0", "stage")).toBe("failed");
    expect(await owner.apply("hunk-0", "stage")).toBe("applied");
    expect(api.stage).toHaveBeenCalledTimes(3);
    owner.dispose();
  });

  test("invalidates old callbacks and late failures when switching repository or closing", async () => {
    const api = operations();
    const pending = deferred();
    api.stage.mockImplementationOnce(() => pending.promise);
    const previous = createMonacoDiffHunkActions(diff, context, api);
    const staleAction = previous.apply;
    const inFlight = staleAction("hunk-0", "stage");
    previous.dispose();
    const current = createMonacoDiffHunkActions(diff, { repoPath: "D:/other", isStaged: true }, api);
    expect(await staleAction("hunk-4", "stage")).toBe("ignored");
    pending.resolve(false);
    expect(await inFlight).toBe("ignored");
    expect(await current.apply("hunk-4", "unstage")).toBe("applied");
    expect(api.stage).toHaveBeenCalledTimes(1);
    expect(api.unstage).toHaveBeenCalledWith("D:/other", { file_path: diff.file_path, lines: diff.lines.slice(4) });
    current.dispose();
    expect(await current.apply("hunk-0", "unstage")).toBe("ignored");
    expect(api.unstage).toHaveBeenCalledTimes(1);
  });

  test("rejects unknown identities, wrong actions, incomplete patches and read-only reviews", async () => {
    const api = operations();
    const owner = createMonacoDiffHunkActions(diff, context, api);
    for (const id of ["hunk-1", "hunk-99", "hunk-00", "line-4", "hunk--1"]) {
      expect(await owner.apply(id, "stage")).toBe("ignored");
    }
    expect(await owner.apply("hunk-0", "unstage")).toBe("ignored");
    expect(await owner.apply("hunk-0", "discard")).toBe("ignored");
    owner.dispose();
    for (const disabled of [
      createMonacoDiffHunkActions(diff, undefined, api),
      createMonacoDiffHunkActions({ ...diff, is_truncated: true }, context, api),
    ]) {
      expect(disabled.action).toBeNull();
      expect(await disabled.apply("hunk-0", "stage")).toBe("ignored");
      disabled.dispose();
    }
    expect(api.stage).not.toHaveBeenCalled();
    expect(api.unstage).not.toHaveBeenCalled();
  });
});
