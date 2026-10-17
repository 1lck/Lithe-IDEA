import { beforeEach, describe, expect, mock, test } from "bun:test";

// All commands the sibling line-history suites may route through this shared
// mock: bun's mock.module registry is global across test files, so whichever
// file registers last must still serve every consumer.
const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.lineHistory") {
    return { baseCommit: "b".repeat(40), unmappedLines: [], commits: [], truncated: false };
  }
  if (command === "git.diff") {
    return [{ file_path: "doc.txt", new_path: "doc.txt", lines: [] }];
  }
  if (command === "git_commit_diff") {
    return [{ file_path: "doc.txt", new_path: "doc.txt", lines: [] }];
  }
  throw new Error(`Unexpected command: ${command}`);
});

// Spread the real module so the override stays scoped to `invoke`; a partial
// mock would strip the sibling exports (Channel, …) from this shared module
// registry for every other test file.
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

const { getGitLineHistory } = await import("./git-line-history-api");
const { clearRepositoryDiscoveryCache } = await import("./git-repo-api");

beforeEach(() => {
  invoke.mockClear();
  clearRepositoryDiscoveryCache();
});

describe("getGitLineHistory", () => {
  test("sends the snapshot and range through the dotted core command", async () => {
    const result = await getGitLineHistory({
      rootPath: "C:/repo",
      filePath: "src/main.ts",
      content: "one\ntwo\n",
      startLine: 2,
      endLine: 2,
      limit: 25,
      operationId: "line-history-1",
    });

    expect(invoke.mock.calls).toEqual([
      ["git_discover_repo", { path: "C:/repo/src" }],
      [
        "git.lineHistory",
        {
          root: "C:/repo",
          path: "src/main.ts",
          content: "one\ntwo\n",
          startLine: 2,
          endLine: 2,
          limit: 25,
          operationId: "line-history-1",
        },
      ],
    ]);
    expect(result?.history.baseCommit).toHaveLength(40);
    expect(result?.repoPath).toBe("C:/repo");
    expect(result?.filePath).toBe("src/main.ts");
  });

  test("skips the core query when cancellation covers the discovery phase", async () => {
    let releaseDiscovery: (() => void) | undefined;
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") {
        await new Promise<void>((resolve) => {
          releaseDiscovery = resolve;
        });
        return "C:/repo";
      }
      throw new Error(`Unexpected command: ${command}`);
    });

    const promise = getGitLineHistory({
      rootPath: "C:/repo",
      filePath: "src/main.ts",
      content: "one\n",
      startLine: 1,
      endLine: 1,
      operationId: "line-history-cancelled",
      isCancelled: () => true,
    });
    // A settled microtask drain lets the discovery resolve; the promise
    // chain contains no timers.
    await Promise.resolve();
    await Promise.resolve();
    releaseDiscovery?.();
    const result = await promise;

    expect(result).toBeNull();
    expect(invoke.mock.calls.some((call) => call[0] === "git.lineHistory")).toBe(false);
  });

  test("returns null when the file is not inside a repository", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") {
        throw new Error("not a git repository");
      }
      throw new Error(`Unexpected command: ${command}`);
    });

    const result = await getGitLineHistory({
      rootPath: "C:/plain",
      filePath: "notes.txt",
      content: "one\n",
      startLine: 1,
      endLine: 1,
      operationId: "line-history-2",
    });

    expect(result).toBeNull();
    expect(invoke.mock.calls).toHaveLength(1);
  });
});
