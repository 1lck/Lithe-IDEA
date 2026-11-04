import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as tauriCore from "@/platform/tauri-core";
import commitSelectionFixture from "../../../../../../shared/fixtures/git/commit-selection-plan-v1.json";

let unavailableRepo: string | null = null;
let statusFailure: Error | null = null;
let rollbackPlan: unknown = { steps: [] };
let rollbackFailure: Error | null = null;
let interceptPrepare: (() => Promise<unknown>) | undefined;
let interceptReserve: (() => Promise<unknown>) | undefined;

let interceptWrite: ((args: Record<string, unknown>) => Promise<unknown>) | undefined;
// Keyed by command: repository discovery may or may not run first, depending
// on what earlier tests in a randomized order have already cached.
let fileDiffResponse: unknown = null;
let statusFiles: unknown[] | null = null;
let directoryListings: Record<string, unknown[]> | null = null;

const invoke = mock(
  async (
    command: string,
    args?: Record<string, unknown>,
    _options?: Parameters<typeof tauriCore.invoke>[2],
  ): Promise<unknown> => {
    if (command === "core_reserve_commit_selection")
      return interceptReserve ? interceptReserve() : true;
    if (command === "git.prepareCommitSelection" && interceptPrepare) return interceptPrepare();
    if (command === "git.rollbackPrepare") {
      if (rollbackFailure) throw rollbackFailure;
      return rollbackPlan;
    }
    if (command === "git.write" && interceptWrite) return interceptWrite(args ?? {});
    if (command === "git_diff_file") return fileDiffResponse;
    if (command === "git.resolveFileContext") {
      const root = String(args?.root ?? "");
      const path = String(args?.path ?? "");
      return { root, path: path.startsWith(`${root}/`) ? path.slice(root.length + 1) : path, ownership: "git" };
    }
    if (command === "git_discover_repo") {
      const path = String(args?.path ?? "");
      return path.startsWith("C:/workspace/") ? path : "C:/repo";
    }
    if (command === "git.untrackedDirectory") {
      const listing = directoryListings?.[String(args?.directory ?? "")];
      if (!listing) throw new Error("Git untracked file listing failed");
      return { files: listing };
    }
    if (command === "git_status") {
      const repoPath = String(args?.repoPath ?? "");
      if (statusFailure) throw statusFailure;
      if (repoPath === unavailableRepo) return null;
      if (statusFiles) return { branch: "main", ahead: 0, behind: 0, files: statusFiles };
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
  },
);

let invokeSpy: ReturnType<typeof spyOn<typeof tauriCore, "invoke">>;

const {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  discardHunk,
  rollbackFilesChanges,
  prepareCommitSelection,
  reconcileDeletedSelection,
  setFilesStaged,
  getWorkspaceGitStatus,
  getWorkspaceRootGitStatus,
  getGitStatus,
  getRepositoryGitStatuses,
} = await import("./git-status-api");
const { isUntrackedDirectoryExpanded, setUntrackedDirectoryExpanded } =
  await import("../services/git-untracked-directory-expansions");
const { getFullContextFileDiff, getWorkingTreePathDiff } = await import("./git-diff-api");
const gitEvents = await import("../events/git-events");

beforeEach(() => {
  invokeSpy = spyOn(tauriCore, "invoke").mockImplementation(invoke as typeof tauriCore.invoke);
  invoke.mockClear();
  interceptWrite = undefined;
  fileDiffResponse = null;
  unavailableRepo = null;
  statusFailure = null;
  rollbackPlan = { steps: [] };
  rollbackFailure = null;
  interceptPrepare = undefined;
  interceptReserve = undefined;
  statusFiles = null;
  directoryListings = null;
});
afterEach(() => invokeSpy.mockRestore());

describe("Git status batch mutations", () => {
  const expectSingleGitWrite = () => {
    expect(invoke.mock.calls.filter(([command]) => command === "git.write")).toHaveLength(1);
  };

  test("stages a directory selection with one shared Core invocation", async () => {
    await expect(
      setFilesStaged("C:/repo", ["src/first.ts", "src/second.ts", "src/first.ts"], true),
    ).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "stage",
      paths: ["src/first.ts", "src/second.ts"],
    });
  });

  test("unstages every selected path with one shared Core invocation", async () => {
    await expect(setFilesStaged("C:/repo", ["src/first.ts", "src/second.ts"], false)).resolves.toBe(
      true,
    );

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "unstage",
      paths: ["src/first.ts", "src/second.ts"],
    });
  });

  test("prepares repository-relative rename and added identities before executing Core steps", async () => {
    const changes = [
      { path: "new.txt", originalPath: "old.txt", status: "R " },
      { path: "added.txt", status: "A " },
    ];
    rollbackPlan = {
      steps: [
        { operation: "discardAll", paths: ["old.txt", "new.txt"] },
        { operation: "unstage", paths: ["added.txt"] },
      ],
    };
    const emitted = spyOn(gitEvents, "emitGitChanged");
    try {
      await rollbackFilesChanges("C:/repo", changes);
      expect(invoke.mock.calls.filter(([command]) => command === "git.rollbackPrepare")).toEqual([
        ["git.rollbackPrepare", { repoPath: "C:/repo", changes, deleteAddedFiles: false }],
      ]);
      expect(invoke.mock.calls.filter(([command]) => command === "git.write")).toEqual([
        [
          "git.write",
          { repoPath: "C:/repo", operation: "discardAll", paths: ["old.txt", "new.txt"] },
        ],
        ["git.write", { repoPath: "C:/repo", operation: "unstage", paths: ["added.txt"] }],
      ]);
      expect(emitted).toHaveBeenCalledWith({
        repoPath: "C:/repo",
        scopes: ["working-tree"],
        source: "rollback-files",
      });
    } finally {
      emitted.mockRestore();
    }
  });

  test("refreshes after a partially failed rollback, but not after a stale preflight", async () => {
    const changes = [{ path: "added.txt", status: "A " }];
    const emitted = spyOn(gitEvents, "emitGitChanged");
    try {
      rollbackFailure = new Error("GIT_ROLLBACK_STALE_SELECTION");
      await expect(rollbackFilesChanges("C:/repo", changes)).rejects.toThrow(
        "GIT_ROLLBACK_STALE_SELECTION",
      );
      expect(invoke.mock.calls.filter(([command]) => command === "git.write")).toHaveLength(0);
      expect(emitted).not.toHaveBeenCalled();
      rollbackFailure = null;
      rollbackPlan = { steps: [{ operation: "unstage", paths: ["added.txt"] }] };
      interceptWrite = async () => {
        throw new Error("write failed");
      };
      await expect(rollbackFilesChanges("C:/repo", changes)).rejects.toThrow("write failed");
      expect(emitted).toHaveBeenCalledWith({
        repoPath: "C:/repo",
        scopes: ["working-tree"],
        source: "rollback-files",
      });
    } finally {
      emitted.mockRestore();
    }
  });

  test("discards one hunk in its owning repository and announces the file change", async () => {
    const hunk = {
      file_path: "src/App.tsx",
      lines: [
        { line_type: "header" as const, content: "@@ -1 +1 @@" },
        { line_type: "removed" as const, content: "old", old_line_number: 1 },
        { line_type: "added" as const, content: "new", new_line_number: 1 },
      ],
    };
    const emitted = spyOn(gitEvents, "emitGitChanged");
    const recorded = () => emitted.mock.calls.map(([change]) => change);
    try {
      await expect(discardHunk("C:/workspace/service-a", hunk)).resolves.toBe(true);
      expect(invoke).toHaveBeenLastCalledWith("git_discard_hunk", {
        repoPath: "C:/workspace/service-a",
        hunk,
      });
      expect(recorded()).toEqual([
        {
          repoPath: "C:/workspace/service-a",
          filePath: "src/App.tsx",
          scopes: ["working-tree"],
          source: "discard-hunk",
        },
      ]);

      // A rejected patch reports failure without announcing a change. Route by
      // command: repository discovery may already be cached in random order.
      invokeSpy.mockImplementation((async (command: string, args?: Record<string, unknown>) => {
        if (command === "git_discard_hunk") throw new Error("patch does not apply");
        return invoke(command, args);
      }) as typeof tauriCore.invoke);
      const error = spyOn(console, "error").mockImplementation(() => {});
      try {
        await expect(discardHunk("C:/repo", hunk)).resolves.toBe(false);
      } finally {
        error.mockRestore();
      }
      expect(recorded()).toHaveLength(1);
    } finally {
      emitted.mockRestore();
    }
  });

  test("adds selected paths to the repository gitignore", async () => {
    await expect(addPathsToGitignore("C:/repo", ["generated/", "local.env"])).resolves.toBe(true);

    expectSingleGitWrite();
    expect(invoke).toHaveBeenLastCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "ignore",
      paths: ["generated/", "local.env"],
    });
  });

  test("adds selected paths to the local Git exclude file", async () => {
    await expect(addPathsToLocalGitExclude("C:/repo", ["generated/"])).resolves.toBe(true);

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
      getWorkspaceGitStatus(
        ["C:/workspace/service-a", "C:/workspace/service-b"],
        "C:/workspace/service-b",
      ),
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

test("workspace status sends all roots to Core for file ownership and preserves the index", async () => {
  const roots = ["C:/workspace/service-a", "C:/workspace/service-b"];
  await getWorkspaceGitStatus(roots);
  const queries = invoke.mock.calls.filter(([command]) => command === "git_status");
  expect(queries).toHaveLength(2);
  for (const [, args] of queries)
    expect(args).toMatchObject({ repositoryRoots: roots, includeIndexOnlyChanges: true });
});

describe("Git status review diffs", () => {
  test("reviews a partially staged path against HEAD before selected-path commit", async () => {
    await expect(getWorkingTreePathDiff("C:/repo", "src/partially-staged.ts")).resolves.toBeNull();

    expect(invoke).toHaveBeenLastCalledWith("git_diff_file", {
      repoPath: "C:/repo",
      filePath: "src/partially-staged.ts",
      worktreeSnapshot: true,
    });
  });

  // #557: a single-file review needs every source line so folded unchanged
  // regions can be expanded; the result is marked for the renderer.
  test("requests the whole file as context for a single-file review", async () => {
    fileDiffResponse = { file_path: "src/App.tsx", lines: [] };
    await expect(
      getWorkingTreePathDiff("C:/repo", "src/App.tsx", false, undefined, true),
    ).resolves.toMatchObject({ is_full_context: true });

    expect(invoke).toHaveBeenLastCalledWith("git_diff_file", {
      repoPath: "C:/repo",
      filePath: "src/App.tsx",
      worktreeSnapshot: true,
      contextLines: 1_073_741_823,
    });
  });

  test("requests a full-context staged diff without the sparse cache", async () => {
    fileDiffResponse = { file_path: "src/App.tsx", lines: [] };
    await expect(getFullContextFileDiff("C:/repo", "src/App.tsx", true)).resolves.toMatchObject({
      is_full_context: true,
    });

    expect(invoke).toHaveBeenLastCalledWith("git_diff_file", {
      repoPath: "C:/repo",
      filePath: "src/App.tsx",
      staged: true,
      contextLines: 1_073_741_823,
    });
  });
});

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
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

  test("reconciles deleted identities through Core using their owning repository", async () => {
    const changes = [
      { path: "new[1].txt", status: "A " },
      { path: "tracked.txt", status: " M" },
    ];
    const emitted = spyOn(gitEvents, "emitGitChanged");
    try {
      await reconcileDeletedSelection("C:/repo", changes);
      expect(invoke).toHaveBeenCalledWith(
        "git.reconcileDeletedSelection",
        { root: "C:/repo", changes },
        { gitExecutionSource: "user" },
      );
      expect(emitted).toHaveBeenCalledWith(
        expect.objectContaining({ repoPath: "C:/repo", source: "reconcile-deleted-selection" }),
      );
    } finally {
      emitted.mockRestore();
    }
  });

  test("forwards the shared commit selection identities to Core", async () => {
    for (const item of commitSelectionFixture.cases) {
      invoke.mockClear();
      await prepareCommitSelection(
        [{ root: "C:/repo", selected: item.selected }],
        "fixture-selection",
        new AbortController().signal,
      );
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.prepareCommitSelection"),
      ).toEqual([
        [
          "git.prepareCommitSelection",
          {
            repositories: [{ root: "C:/repo", selected: item.selected }],
            operationId: "fixture-selection",
          },
          { gitExecutionSource: "user" },
        ],
      ]);
    }
  }, 1000);

  test("commit selection waits for an existing index write and forwards all roots", async () => {
    const started = deferred(),
      release = deferred();
    interceptWrite = async () => {
      started.resolve();
      await release.promise;
    };
    const staging = setFilesStaged("C:/workspace/A", ["earlier.ts"], true);
    const operations: Promise<unknown>[] = [staging];
    try {
      await started.promise;
      const selection = prepareCommitSelection(
        [
          { root: "C:/workspace/B", selected: [{ path: "src/b.ts", status: "MM" }] },
          { root: "C:/workspace/A", selected: [] },
        ],
        "commit-selection-test",
        new AbortController().signal,
      );
      operations.push(selection);
      await Promise.resolve();
      await Promise.resolve();
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.prepareCommitSelection"),
      ).toHaveLength(0);
      release.resolve();
      await selection;
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.prepareCommitSelection"),
      ).toEqual([
        [
          "git.prepareCommitSelection",
          {
            repositories: [
              { root: "C:/workspace/A", selected: [] },
              { root: "C:/workspace/B", selected: [{ path: "src/b.ts", status: "MM" }] },
            ],
            operationId: "commit-selection-test",
          },
          { gitExecutionSource: "user" },
        ],
      ]);
    } finally {
      release.resolve();
      await Promise.allSettled(operations);
    }
  }, 1000);

  test("cancelling while admission is pending never dispatches a Core write", async () => {
    const started = deferred(),
      release = deferred();
    interceptReserve = async () => {
      started.resolve();
      await release.promise;
      return true;
    };
    const controller = new AbortController();
    const operation = prepareCommitSelection(
      [{ root: "C:/repo", selected: [{ path: "a.ts", status: " M" }] }],
      "reserve-selection-test",
      controller.signal,
    );
    try {
      await started.promise;
      controller.abort();
      release.resolve();
      await expect(operation).rejects.toMatchObject({ name: "AbortError" });
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.prepareCommitSelection"),
      ).toHaveLength(0);
      expect(
        invoke.mock.calls.filter(([command]) => command === "core_release_commit_selection"),
      ).toEqual([["core_release_commit_selection", { operationId: "reserve-selection-test" }]]);
    } finally {
      controller.abort();
      release.resolve();
      await Promise.allSettled([operation]);
    }
  }, 1000);

  test("cancelling a running commit selection cancels Core and rejects late completion", async () => {
    const started = deferred(),
      release = deferred();
    interceptPrepare = async () => {
      started.resolve();
      await release.promise;
      return { prepared: true };
    };
    const controller = new AbortController();
    const operation = prepareCommitSelection(
      [{ root: "C:/repo", selected: [{ path: "a.ts", status: " M" }] }],
      "cancel-selection-test",
      controller.signal,
    );
    try {
      await started.promise;
      controller.abort();
      expect(invoke.mock.calls.filter(([command]) => command === "core_cancel")).toEqual([
        ["core_cancel", { operationId: "cancel-selection-test" }],
      ]);
      release.resolve();
      await expect(operation).rejects.toMatchObject({ name: "AbortError" });
    } finally {
      controller.abort();
      release.resolve();
      await Promise.allSettled([operation]);
    }
  }, 1000);

  test("prepares rollback only after the pending staging operation finishes", async () => {
    const started = deferred();
    const release = deferred();
    interceptWrite = async () => {
      started.resolve();
      await release.promise;
    };
    const staging = setFilesStaged("C:/repo", ["added.txt"], true);
    const operations: Promise<unknown>[] = [staging];
    try {
      await started.promise;
      rollbackPlan = { steps: [] };
      const rollback = rollbackFilesChanges("C:/repo", [{ path: "added.txt", status: "A " }]);
      operations.push(rollback);
      await Promise.resolve();
      await Promise.resolve();
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.rollbackPrepare"),
      ).toHaveLength(0);
      release.resolve();
      await rollback;
      expect(
        invoke.mock.calls.filter(([command]) => command === "git.rollbackPrepare"),
      ).toHaveLength(1);
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
  test("bootstrap preserves root-relative paths while reading every discovered repository", async () => {
    const snapshot = await getWorkspaceRootGitStatus("C:/repo", [
      "C:/repo",
      "C:/workspace/service-a",
      "C:/workspace/service-b",
    ]);
    expect(snapshot?.files.map((file) => file.path)).toEqual(["src/App.tsx"]);
    const queriedRepos = invoke.mock.calls
      .filter(([command]) => command === "git_status")
      .map(([, args]) => args?.repoPath);
    expect(queriedRepos.sort()).toEqual([
      "C:/repo",
      "C:/workspace/service-a",
      "C:/workspace/service-b",
    ]);
  });

  test("bootstrap reports a child repository failure even when the root status succeeds", async () => {
    unavailableRepo = "C:/workspace/service-b";
    await expect(
      getWorkspaceRootGitStatus("C:/repo", ["C:/repo", "C:/workspace/service-b"]),
    ).rejects.toThrow("no snapshot");
  });

  test("rejects an empty snapshot for a selected repository and recovers on retry", async () => {
    unavailableRepo = "C:/repo";
    await expect(getWorkspaceGitStatus(["C:/repo"])).rejects.toThrow("no snapshot");
    unavailableRepo = null;
    expect((await getWorkspaceGitStatus(["C:/repo"]))?.files).toHaveLength(1);
  });

  test("does not return a partial workspace when one repository is unavailable", async () => {
    unavailableRepo = "C:/workspace/service-b";
    await expect(
      getWorkspaceGitStatus(["C:/workspace/service-a", "C:/workspace/service-b"]),
    ).rejects.toThrow("no snapshot");
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

describe("Untracked directory summaries", () => {
  const repo = "C:/workspace/summaries";
  const untracked = (path: string, untrackedFileCount?: number) => ({
    path,
    status: "untracked",
    staged: false,
    ...(untrackedFileCount === undefined ? {} : { untrackedFileCount }),
  });
  const paths = async () =>
    ((await getRepositoryGitStatuses([repo]))[repo]?.files ?? []).map((file) => file.path);

  test("store reads summarize large directories while one-off reads stay file-level", async () => {
    // Regression for #1385: an unignored build directory published one record per file.
    statusFiles = [untracked("target/", 5_273)];
    await expect(paths()).resolves.toEqual(["target/"]);
    await getGitStatus(repo);
    const queries = invoke.mock.calls.filter(([command]) => command === "git_status");
    expect(queries[0]?.[1]).toMatchObject({ summarizeUntrackedDirectories: true });
    expect(queries[1]?.[1]).not.toHaveProperty("summarizeUntrackedDirectories");
  });

  test("lists expanded summaries on every read and forgets them once the summary is gone", async () => {
    statusFiles = [untracked("src/App.tsx"), untracked("target/", 5_273)];
    directoryListings = {
      "target/": [untracked("target/.rustc_info.json"), untracked("target/debug/", 5_272)],
      "target/debug/": [untracked("target/debug/app")],
    };
    try {
      setUntrackedDirectoryExpanded(repo, "target/", true);
      setUntrackedDirectoryExpanded(repo, "target/debug/", true);
      const expanded = [
        "src/App.tsx",
        "target/",
        "target/.rustc_info.json",
        "target/debug/",
        "target/debug/app",
      ];
      await expect(paths()).resolves.toEqual(expanded);
      expect(
        invoke.mock.calls.find(([command]) => command === "git.untrackedDirectory")?.[1],
      ).toMatchObject({ repoPath: repo, directory: "target/", repositoryRoots: [repo] });

      // A failed listing keeps the summary collapsed and retries on the next read.
      directoryListings = null;
      const logged = spyOn(console, "error").mockImplementation(() => {});
      try {
        await expect(paths()).resolves.toEqual(["src/App.tsx", "target/"]);
        expect(logged).toHaveBeenCalledTimes(1);
      } finally {
        logged.mockRestore();
      }
      expect(isUntrackedDirectoryExpanded(repo, "target/")).toBe(true);

      // Staging or deleting the directory removes its summary and its expansion.
      statusFiles = [untracked("src/App.tsx")];
      await expect(paths()).resolves.toEqual(["src/App.tsx"]);
      expect(isUntrackedDirectoryExpanded(repo, "target/")).toBe(false);
      expect(isUntrackedDirectoryExpanded(repo, "target/debug/")).toBe(false);
    } finally {
      setUntrackedDirectoryExpanded(repo, "target/", false);
    }
  });
});
