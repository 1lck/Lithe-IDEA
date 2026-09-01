import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (command: string): Promise<unknown> =>
  command === "git_discover_repo" ? "C:/repo" : null,
);

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  addPathsToGitignore,
  addPathsToLocalGitExclude,
  rollbackFilesChanges,
  setFilesStaged,
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
