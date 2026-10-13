import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import * as gitEvents from "../events/git-events";

let gitWriteResult = { output: "", exitCode: 0 };
let gitWriteError: Error | null = null;
let gitReadError: unknown = null;
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

let commitLookupResult: unknown = null;
let commitLookupError: unknown = null;

const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.commit") {
    if (commitLookupError) throw commitLookupError;
    return commitLookupResult;
  }
  if (command === "git.write") {
    if (gitWriteError) throw gitWriteError;
    return gitWriteResult;
  }
  if ((command === "git_references" || command === "git_history_page") && gitReadError) {
    throw gitReadError;
  }
  return null;
});

const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

const {
  cherryPickCommit,
  commitSelectedChanges,
  getCommitDescription,
  getGitHistoryPage,
  getGitReferences,
  getGitReferencesAtRoot,
  resetToCommit,
  revertCommit,
  withCommitDescription,
} = await import("./git-commits-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  gitWriteResult = { output: "", exitCode: 0 };
  gitWriteError = null;
  gitReadError = null;
  commitLookupResult = null;
  commitLookupError = null;
});

describe("Git commit message details", () => {
  const listedCommit = {
    hash: "detail-subject-only",
    shortHash: "detail",
    parentHashes: [],
    message: "Fix commit details",
    author: "Developer",
    date: "2026/08/16 10:00",
    decorations: "",
  };

  // Regression for #771: history rows only carry the subject, so the full
  // message must come from the shared single-commit lookup.
  test("reads the body through git.commit and reuses it for the same commit", async () => {
    // The shared fixture is the Rust Core response shape for `git.commit`.
    const fixture = JSON.parse(
      readFileSync(
        new URL(
          "../../../../../../shared/fixtures/git/commit-lookup-response-v1.json",
          import.meta.url,
        ),
        "utf8",
      ),
    ) as { body: string };
    commitLookupResult = fixture;

    expect(await getCommitDescription("C:/repo", "detail-cached")).toBe(fixture.body);
    expect(await getCommitDescription("C:/repo", "detail-cached")).toBe(fixture.body);

    const lookups = invoke.mock.calls.filter(([command]) => command === "git.commit");
    expect(lookups).toEqual([["git.commit", { repoPath: "C:/repo", commit: "detail-cached" }]]);
  });

  test("treats a subject-only commit as an empty description", async () => {
    commitLookupResult = { commit: { hash: listedCommit.hash }, body: "" };

    expect(await withCommitDescription("C:/repo", listedCommit)).toEqual({
      ...listedCommit,
      description: "",
    });
  });

  test("keeps the subject-only commit and retries later when the lookup fails", async () => {
    const consoleError = spyOn(console, "error").mockImplementation(() => {});
    try {
      commitLookupError = new Error("commit lookup failed");
      const commit = { ...listedCommit, hash: "detail-retry" };

      expect(await withCommitDescription("C:/repo", commit)).toBe(commit);
      expect(consoleError).toHaveBeenCalledWith("Failed to get commit details:", commitLookupError);

      commitLookupError = null;
      commitLookupResult = { commit: { hash: "detail-retry" }, body: "Recovered body" };
      expect(await getCommitDescription("C:/repo", "detail-retry")).toBe("Recovered body");
    } finally {
      consoleError.mockRestore();
    }
  });

  test("does not re-read a commit whose description is already known", async () => {
    const commit = { ...listedCommit, hash: "detail-known", description: "Known body" };

    expect(await withCommitDescription("C:/repo", commit)).toBe(commit);
    expect(invoke.mock.calls.some(([command]) => command === "git.commit")).toBe(false);
  });
});

describe("Git commit history reads", () => {
  test("first and continuation pages use the shared IDEA date-order contract", async () => {
    const fixture = JSON.parse(
      readFileSync(
        new URL(
          "../../../../../../shared/fixtures/git/history-page-date-request-v1.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    await getGitHistoryPage("C:/repo", undefined, 50, "date-first", "refs/heads/main");
    await getGitHistoryPage("C:/repo", "date-cursor", 50, "date-next", "refs/heads/main");
    const pages = invoke.mock.calls.filter(([command]) => command === "git_history_page");
    expect(pages).toHaveLength(2);
    expect(pages.map(([, args]) => args)).toEqual([
      {
        repoPath: "C:/repo",
        limit: 50,
        operationId: "date-first",
        reference: "refs/heads/main",
        order: fixture.order,
      },
      {
        repoPath: "C:/repo",
        limit: 50,
        operationId: "date-next",
        reference: "refs/heads/main",
        cursor: "date-cursor",
        order: fixture.order,
      },
    ]);
  });

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
      expect(consoleError).toHaveBeenCalledWith("Failed to get git history page:", gitReadError);
    } finally {
      consoleError.mockRestore();
    }
  });

  test("reads references from a known root without resolving the repository", async () => {
    await getGitReferencesAtRoot("C:/repo-b", "references-root");

    const commands = invoke.mock.calls.map(([command]) => command);
    expect(commands).not.toContain("git_discover_repo");
    expect(invoke).toHaveBeenCalledWith("git_references", {
      repoPath: "C:/repo-b",
      operationId: "references-root",
    });
  });
});

describe("Git commit history mutations", () => {
  test("sends typed reset, cherry-pick, revert, and selected commit requests", async () => {
    await resetToCommit("C:/repo", "a1", "mixed");
    await cherryPickCommit("C:/repo", "d4");
    await revertCommit("C:/repo", "e5");
    await commitSelectedChanges("C:/repo", "selected", ["new.txt", "changed.txt"]);

    const writes = invoke.mock.calls.filter(([command]) => command === "git.write");
    expect(writes).toEqual([
      ["git.write", { repoPath: "C:/repo", operation: "reset", revision: "a1", mode: "--mixed" }],
      ["git.write", { repoPath: "C:/repo", operation: "cherryPick", revision: "d4" }],
      ["git.write", { repoPath: "C:/repo", operation: "revert", revision: "e5" }],
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
