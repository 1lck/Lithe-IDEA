import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (command: string, args?: Record<string, unknown>): Promise<unknown> => {
  if (command === "git_discover_repo") {
    const path = String(args?.path ?? "");
    return path.startsWith("C:/workspace/") ? path : "C:/repo";
  }
  if (command === "git_status") {
    const repoPath = String(args?.repoPath ?? "");
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

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  rollbackFilesChanges,
  setFilesStaged,
  getWorkspaceGitStatus,
} = await import("./git-status-api");
const { getWorkingTreePathDiff } = await import("./git-diff-api");

beforeEach(() => {
  invoke.mockClear();
});

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
