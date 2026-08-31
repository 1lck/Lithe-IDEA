import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

let gitWriteResult = { output: "", exitCode: 0 };
let gitWriteError: Error | null = null;
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.write") {
    if (gitWriteError) throw gitWriteError;
    return gitWriteResult;
  }
  return null;
});

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  cherryPickCommit,
  commitSelectedChanges,
  deleteCommit,
  editCommitMessage,
  resetToCommit,
  squashCommits,
} = await import("./git-commits-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  gitWriteResult = { output: "", exitCode: 0 };
  gitWriteError = null;
});

describe("Git commit history mutations", () => {
  test("sends typed edit, delete, squash, reset, and cherry-pick requests", async () => {
    await editCommitMessage("C:/repo", "a1", "edited");
    await deleteCommit("C:/repo", "b2");
    await squashCommits("C:/repo", ["c3", "b2"], "squashed");
    await resetToCommit("C:/repo", "a1", "mixed");
    await cherryPickCommit("C:/repo", "d4");
    await commitSelectedChanges("C:/repo", "selected", ["new.txt", "changed.txt"]);

    const writes = invoke.mock.calls.filter(([command]) => command === "git.write");
    expect(writes).toEqual([
      [
        "git.write",
        { repoPath: "C:/repo", operation: "editCommitMessage", revision: "a1", message: "edited" },
      ],
      ["git.write", { repoPath: "C:/repo", operation: "deleteCommit", revision: "b2" }],
      [
        "git.write",
        {
          repoPath: "C:/repo",
          operation: "squashCommits",
          revisions: ["c3", "b2"],
          message: "squashed",
        },
      ],
      ["git.write", { repoPath: "C:/repo", operation: "reset", revision: "a1", mode: "--mixed" }],
      ["git.write", { repoPath: "C:/repo", operation: "cherryPick", revision: "d4" }],
      [
        "git.write",
        {
          repoPath: "C:/repo",
          operation: "commit",
          message: "selected",
          paths: ["new.txt", "changed.txt"],
        },
      ],
    ]);
  });

  test("rejects a non-zero Git result instead of reporting success", async () => {
    gitWriteResult = { output: "commit failed", exitCode: 1 };

    await expect(commitSelectedChanges("C:/repo", "selected", ["changed.txt"])).rejects.toThrow(
      "commit failed",
    );
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs"],
      source: "commit",
    });
  });

  test("refreshes repository state when a history mutation rejects", async () => {
    gitWriteError = new Error("cherry-pick stopped with conflicts");

    await expect(cherryPickCommit("C:/repo", "d4")).rejects.toThrow(
      "cherry-pick stopped with conflicts",
    );
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs"],
      source: "cherry-pick-commit",
    });
  });
});
