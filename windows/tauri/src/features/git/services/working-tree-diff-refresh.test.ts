import { describe, expect, test } from "bun:test";
import type { MultiFileDiff, WorkingTreeDiffTarget } from "../types/git-diff.types";
import type { GitDiff, GitFile, GitStatus } from "../types/git.types";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";
import {
  refreshWorkingTreeFileDiff,
  type WorkingTreeDiffBufferPort,
} from "./working-tree-diff-refresh";

const BUFFER_ID = "diff-buffer";
const REPO = "C:/work/repo";
const FILE_KEY = "unstaged:app/src/Main.java";
const TARGET: WorkingTreeDiffTarget = {
  repoPath: REPO,
  filePath: "src/Main.java",
  untracked: false,
};

function diffWithLines(lineCount: number): GitDiff {
  return {
    file_path: "src/Main.java",
    is_new: false,
    is_deleted: false,
    is_renamed: false,
    lines: Array.from({ length: lineCount }, (_, index) => ({
      line_type: "added" as const,
      content: `line ${index}`,
      new_line_number: index + 1,
    })),
  };
}

function status(files: GitFile[]): GitStatus {
  return { branch: "main", ahead: 0, behind: 0, files };
}

function statusFile(overrides: Partial<GitFile> = {}): GitFile {
  return { path: "src/Main.java", status: "modified", staged: false, ...overrides };
}

function openedDiff(target: WorkingTreeDiffTarget = TARGET): MultiFileDiff {
  return createSingleFileWorkingTreeDiff({
    repoPath: REPO,
    fileKey: FILE_KEY,
    diff: diffWithLines(2),
    title: "Uncommitted Changes",
    target,
  });
}

function bufferPort(initial: MultiFileDiff | null) {
  let current = initial;
  const closed: string[] = [];
  const port: WorkingTreeDiffBufferPort = {
    read: () => current,
    replace: (_bufferId, diff) => {
      current = diff;
    },
    close: (bufferId) => {
      closed.push(bufferId);
      current = null;
    },
  };
  return {
    port,
    closed,
    current: () => current,
    setCurrent: (diff: MultiFileDiff | null) => {
      current = diff;
    },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
}

describe("refreshWorkingTreeFileDiff", () => {
  test("reloads an untracked file with the snapshot semantics used to open it", async () => {
    // Regression for #773: the old index-based refresh found no diff for
    // untracked files and closed the tab right after it opened.
    const buffers = bufferPort(openedDiff({ ...TARGET, untracked: true }));
    const diffRequests: unknown[][] = [];

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () => status([statusFile({ status: "untracked" })]),
        loadDiff: async (...args) => {
          diffRequests.push(args);
          return diffWithLines(3);
        },
      },
    );

    expect(outcome).toBe("updated");
    expect(buffers.closed).toEqual([]);
    expect(diffRequests).toEqual([[REPO, "src/Main.java", true, undefined]]);
    expect(buffers.current()?.files[0]?.lines).toHaveLength(3);
    expect(buffers.current()?.workingTreeTargets?.[FILE_KEY]?.untracked).toBe(true);
  });

  test("matches status by repository-relative path, not the workspace display path", async () => {
    const buffers = bufferPort(openedDiff());

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () =>
          status([
            statusFile({
              path: "app/src/Main.java",
              repositoryPath: REPO,
              repositoryRelativePath: "src/Main.java",
            }),
          ]),
        loadDiff: async () => diffWithLines(1),
      },
    );

    expect(outcome).toBe("updated");
    expect(buffers.closed).toEqual([]);
  });

  test("keeps the tab with an empty state when a listed file has no remaining diff", async () => {
    const buffers = bufferPort(openedDiff());

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () => status([statusFile()]),
        loadDiff: async () => diffWithLines(0),
      },
    );

    expect(outcome).toBe("updated");
    expect(buffers.closed).toEqual([]);
    expect(buffers.current()?.files).toEqual([]);
    expect(buffers.current()?.initiallyExpandedFileKey).toBe(FILE_KEY);
    expect(buffers.current()?.workingTreeTargets?.[FILE_KEY]).toEqual(TARGET);
  });

  test("leaves the buffer untouched when the reloaded diff is identical", async () => {
    // Metadata-only Git changes must not rebuild the review editor; each
    // rebuild used to move a scrolled diff by the action zones above it.
    const opened = openedDiff();
    const buffers = bufferPort(opened);
    let replacements = 0;
    const port: WorkingTreeDiffBufferPort = {
      ...buffers.port,
      replace: (bufferId, diff) => {
        replacements += 1;
        buffers.port.replace(bufferId, diff);
      },
    };

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: port,
        loadStatus: async () => status([statusFile()]),
        loadDiff: async () => diffWithLines(2),
      },
    );

    expect(outcome).toBe("unchanged");
    expect(replacements).toBe(0);
    expect(buffers.current()).toBe(opened);
  });

  test("closes the tab only when Git status no longer lists the file", async () => {
    const buffers = bufferPort(openedDiff());
    let diffLoads = 0;

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () => status([statusFile({ path: "src/Other.java" })]),
        loadDiff: async () => {
          diffLoads += 1;
          return diffWithLines(1);
        },
      },
    );

    expect(outcome).toBe("closed");
    expect(buffers.closed).toEqual([BUFFER_ID]);
    expect(diffLoads).toBe(0);
  });

  test("keeps current content when status or diff reads fail", async () => {
    const opened = openedDiff();
    const buffers = bufferPort(opened);

    const statusFailure = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      { buffers: buffers.port, loadStatus: async () => null, loadDiff: async () => diffWithLines(1) },
    );
    const diffFailure = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () => status([statusFile()]),
        loadDiff: async () => null,
      },
    );

    expect([statusFailure, diffFailure]).toEqual(["skipped", "skipped"]);
    expect(buffers.closed).toEqual([]);
    expect(buffers.current()).toBe(opened);
  });

  test("drops a stale result after another open replaces the buffer", async () => {
    // Event order: refresh starts, a newer diff replaces the buffer while the
    // status read is pending, then the stale status read resolves.
    const buffers = bufferPort(openedDiff());
    const pendingStatus = deferred<GitStatus | null>();
    const refresh = refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: () => pendingStatus.promise,
        loadDiff: async () => diffWithLines(5),
      },
    );
    const newer = openedDiff();
    buffers.setCurrent(newer);
    pendingStatus.resolve(status([]));

    expect(await refresh).toBe("skipped");
    expect(buffers.closed).toEqual([]);
    expect(buffers.current()).toBe(newer);
  });

  test("does not refresh diffs opened without a working-tree target", async () => {
    const buffers = bufferPort(
      createSingleFileWorkingTreeDiff({ repoPath: REPO, fileKey: FILE_KEY, diff: diffWithLines(1) }),
    );
    let statusLoads = 0;

    const outcome = await refreshWorkingTreeFileDiff(
      { bufferId: BUFFER_ID, fileKey: FILE_KEY },
      {
        buffers: buffers.port,
        loadStatus: async () => {
          statusLoads += 1;
          return status([]);
        },
      },
    );

    expect(outcome).toBe("skipped");
    expect(statusLoads).toBe(0);
    expect(buffers.closed).toEqual([]);
  });
});
