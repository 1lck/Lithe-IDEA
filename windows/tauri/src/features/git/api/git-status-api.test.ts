import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as tauriCore from "@/platform/tauri-core";

let unavailableRepo: string | null = null;
let statusFailure: Error | null = null;

let interceptWrite: ((args: Record<string, unknown>) => Promise<unknown>) | undefined;

const invoke = mock(async (command: string, args?: Record<string, unknown>): Promise<unknown> => {
  if (command === "git.write" && interceptWrite) return interceptWrite(args ?? {});
  if (command === "git_discover_repo") {
    const path = String(args?.path ?? "");
    return path.startsWith("C:/workspace/") ? path : "C:/repo";
  }
  if (command === "git_status") {
    const repoPath = String(args?.repoPath ?? "");
    if (statusFailure) throw statusFailure;
    if (repoPath === unavailableRepo) return null;
    return {
      branch: repoPath.endsWith("service-a") ? "main" : "develop",
      ahead: repoPath.endsWith("service-a") ? 1 : 0,
      behind: repoPath.endsWith("service-b") ? 2 : 0,
      files: [
        {
          path: "src/App.tsx",
          status: "modified",
          staged: repoPath.endsWith("service-b"),
        },
      ],
    };
  }
  return null;
});

let invokeSpy: ReturnType<typeof spyOn<typeof tauriCore, "invoke">>;

const {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  rollbackFilesChanges,
  setFilesStaged,
  getWorkspaceGitStatus,
  getGitStatus,
} = await import("./git-status-api");
const { getWorkingTreePathDiff } = await import("./git-diff-api");

beforeEach(() => {
  invokeSpy = spyOn(tauriCore, "invoke").mockImplementation(invoke as typeof tauriCore.invoke);
  invoke.mockClear();
  interceptWrite = undefined;
  unavailableRepo = null;
  statusFailure = null;
});
afterEach(() => invokeSpy.mockRestore());

describe("Git status batch mutations", () => {
  const expectSingleGitWrite = () => {
    expect(
      invoke.mock.calls.filter(([command]) => command === "git.write"),
    ).toHaveLength(1);
  };

  test("stages a directory selection with one shared Core invocation", async () => {
    await expect(
      setFilesStaged(
        "C:/repo",
        ["src/first.ts", "src/second.ts", "src/first.ts"],
        true,
      ),
    ).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "stage",
      paths: ["src/first.ts", "src/second.ts"],
    });
  });

  test("unstages every selected path with one shared Core invocation", async () => {
    await expect(
      setFilesStaged("C:/repo", ["src/first.ts", "src/second.ts"], false),
    ).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "unstage",
      paths: ["src/first.ts", "src/second.ts"],
    });
  });

  test("rolls back selected tracked paths with one shared Core invocation", async () => {
    await expect(
      rollbackFilesChanges("C:/repo", ["src/first.ts", "src/second.ts"]),
    ).resolves.toBeUndefined();

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "discardAll",
      paths: ["src/first.ts", "src/second.ts"],
    });
  });

  test("adds selected paths to the repository gitignore", async () => {
    await expect(
      addPathsToGitignore("C:/repo", ["generated/", "local.env"]),
    ).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "ignore",
      paths: ["generated/", "local.env"],
    });
  });

  test("adds selected paths to the local Git exclude file", async () => {
    await expect(
      addPathsToLocalGitExclude("C:/repo", ["generated/"]),
    ).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "exclude",
      paths: ["generated/"],
    });
  });
});

describe("Workspace Git status", () => {
  test("aggregates changed files from every discovered repository", async () => {
    await expect(
      getWorkspaceGitStatus(["C:/workspace/service-a", "C:/workspace/service-b"], "C:/workspace/service-b"),
    ).resolves.toEqual({
      branch: "develop",
      ahead: 0,
      behind: 2,
      files: [
        {
          path: "service-a/src/App.tsx",
          status: "modified",
          staged: false,
          repositoryPath: "C:/workspace/service-a",
          repositoryRelativePath: "src/App.tsx",
          repositoryOriginalRelativePath: undefined,
        },
        {
          path: "service-b/src/App.tsx",
          status: "modified",
          staged: true,
          repositoryPath: "C:/workspace/service-b",
          repositoryRelativePath: "src/App.tsx",
          repositoryOriginalRelativePath: undefined,
        },
      ],
    });
  });
});

describe("Git status review diffs", () => {
  test("reviews a partially staged path against HEAD before selected-path commit", async () => {
    await expect(
      getWorkingTreePathDiff("C:/repo", "src/partially-staged.ts"),
    ).resolves.toBeNull();

    expect(invoke).toHaveBeenLastCalledWith("git_diff_file", {
      repoPath: "C:/repo",
      filePath: "src/partially-staged.ts",
      worktreeSnapshot: true,
    });
  });
});

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("Git staging write coordination", () => {
  test("queues a second file and a bulk action behind a pending file", async () => {
    const started = deferred();
    const release = deferred();
    const writes: string[][] = [];
    interceptWrite = async (args) => {
      writes.push(args.paths as string[]);
      if (writes.length === 1) {
        started.resolve();
        await release.promise;
      }
    };
    const first = setFilesStaged("C:/repo", ["a.ts"], true);
    const operations: Promise<boolean>[] = [first];
    try {
      await started.promise;
      operations.push(setFilesStaged("C:/repo", ["b.ts"], true));
      operations.push(setFilesStaged("C:/repo", ["a.ts", "b.ts"], false));
      // Cross the repository-resolution and queue-enqueue microtask boundaries.
      await Promise.resolve();
      await Promise.resolve();
      expect(writes).toEqual([["a.ts"]]);
      release.resolve();
      expect(await Promise.all(operations)).toEqual([true, true, true]);
      expect(writes).toEqual([["a.ts"], ["b.ts"], ["a.ts", "b.ts"]]);
    } finally {
      release.resolve();
      await Promise.allSettled(operations);
      interceptWrite = undefined;
    }
  }, 1000);

  test("allows another repository to finish while the first is pending", async () => {
    const started = deferred();
    const release = deferred();
    interceptWrite = async (args) => {
      if (args.repoPath === "C:/workspace/service-a") {
        started.resolve();
        await release.promise;
      }
    };
    const operations = [setFilesStaged("C:/workspace/service-a", ["a.ts"], true)];
    try {
      await started.promise;
      const other = setFilesStaged("C:/workspace/service-b", ["b.ts"], true);
      operations.push(other);
      expect(await other).toBe(true);
    } finally {
      release.resolve();
      await Promise.allSettled(operations);
      interceptWrite = undefined;
    }
  }, 1000);

  test("returns the write failure and keeps queued and later staging usable", async () => {
    const started = deferred();
    const release = deferred();
    const failure = new Error("index.lock is held by another Git process");
    let writes = 0;
    interceptWrite = async () => {
      if (++writes === 1) {
        started.resolve();
        await release.promise;
        throw failure;
      }
    };
    const failed = setFilesStaged("C:/repo", ["a.ts"], true).catch((error: unknown) => error);
    const operations: Promise<unknown>[] = [failed];
    try {
      await started.promise;
      const queued = setFilesStaged("C:/repo", ["b.ts"], true);
      operations.push(queued);
      release.resolve();
      expect(await failed).toBe(failure);
      expect(await queued).toBe(true);
      expect(await setFilesStaged("C:/repo", ["c.ts"], true)).toBe(true);
    } finally {
      release.resolve();
      await Promise.allSettled(operations);
      interceptWrite = undefined;
    }
  }, 1000);
});

describe("Git status query failures", () => {
  test("rejects an empty snapshot for a selected repository and recovers on retry", async () => {
    unavailableRepo = "C:/repo";
    await expect(getWorkspaceGitStatus(["C:/repo"])).rejects.toThrow("no snapshot");
    unavailableRepo = null;
    expect((await getWorkspaceGitStatus(["C:/repo"]))?.files).toHaveLength(1);
  });

  test("does not return a partial workspace when one repository is unavailable", async () => {
    unavailableRepo = "C:/workspace/service-b";
    await expect(getWorkspaceGitStatus([
      "C:/workspace/service-a", "C:/workspace/service-b",
    ])).rejects.toThrow("no snapshot");
  });

  test("propagates native query failures to workspace refresh", async () => {
    statusFailure = new Error("Git status unavailable");
    await expect(getWorkspaceGitStatus(["C:/repo"])).rejects.toThrow("Git status unavailable");
  });

  test("keeps the nullable API for optional status consumers", async () => {
    unavailableRepo = "C:/repo";
    await expect(getGitStatus("C:/repo")).resolves.toBeNull();
  });

  test("keeps an empty repository list distinct from a failed query", async () => {
    await expect(getWorkspaceGitStatus([])).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });
});
