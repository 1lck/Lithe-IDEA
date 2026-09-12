import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

let gitWriteResult = { output: "", exitCode: 0 };
let gitWriteError: Error | null = null;
let gitReadError: unknown = null;
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.write") {
    if (gitWriteError) throw gitWriteError;
    return gitWriteResult;
  }
  if ((command === "git_references" || command === "git_history_page") && gitReadError) {
    throw gitReadError;
  }
  return null;
});

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  cherryPickCommit,
  commitSelectedChanges,
  getGitHistoryPage,
  getGitReferences,
  resetToCommit,
} = await import("./git-commits-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  gitWriteResult = { output: "", exitCode: 0 };
  gitWriteError = null;
  gitReadError = null;
});

describe("Git commit history reads", () => {
  test("keeps superseded reference and page request cancellation out of error logs", async () => {
    const consoleError = spyOn(console, "error").mockImplementation(() => {});

    try {
      gitReadError = Object.assign(new Error("superseded"), { code: "cancelled" });
      expect(await getGitReferences("C:/repo", "references-1")).toBeNull();

      gitReadError = "Operation was cancelled";
      expect(await getGitHistoryPage("C:/repo", undefined, 50, "page-1")).toBeNull();

      expect(consoleError).not.toHaveBeenCalled();
    } finally {
      consoleError.mockRestore();
    }
  });

  test("continues logging unexpected history read failures", async () => {
    const consoleError = spyOn(console, "error").mockImplementation(() => {});

    try {
      gitReadError = new Error("history backend unavailable");

      expect(await getGitHistoryPage("C:/repo", undefined, 50, "page-2")).toBeNull();
      expect(consoleError).toHaveBeenCalledWith(
        "Failed to get git history page:",
        gitReadError,
      );
    } finally {
      consoleError.mockRestore();
    }
  });
});

describe("Git commit history mutations", () => {
  test("sends typed reset, cherry-pick, and selected commit requests", async () => {
    await resetToCommit("C:/repo", "a1", "mixed");
    await cherryPickCommit("C:/repo", "d4");
    await commitSelectedChanges("C:/repo", "selected", ["new.txt", "changed.txt"]);

    const writes = invoke.mock.calls.filter(([command]) => command === "git.write");
    expect(writes).toEqual([
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
