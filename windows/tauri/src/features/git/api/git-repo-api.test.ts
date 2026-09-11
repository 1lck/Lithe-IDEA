import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);
const readDirectory = mock(async (_path: string): Promise<unknown[]> => []);

mock.module("@/platform/tauri-core", () => ({ invoke }));
mock.module("@/features/file-system/controllers/platform", () => ({ readDirectory }));

const {
  clearRepositoryDiscoveryCache,
  discoverWorkspaceRepositories,
  normalizeRepositoryPath,
  resolveRepositoryForFile,
} = await import("./git-repo-api");

beforeEach(() => {
  invoke.mockReset();
  readDirectory.mockReset();
  clearRepositoryDiscoveryCache();
});

describe("discoverWorkspaceRepositories", () => {
  test("a slower older scan cannot replace a forced refresh in the cache", async () => {
    let completeOlder!: (value: unknown) => void;
    const olderResult = new Promise<unknown>((resolve) => { completeOlder = resolve; });
    invoke.mockImplementationOnce(() => olderResult);
    invoke.mockResolvedValue({ repositories: [{ path: "D:/work/new" }] });
    const olderScan = discoverWorkspaceRepositories("D:/work");
    try {
      expect(await discoverWorkspaceRepositories("D:/work", { force: true })).toEqual(["D:/work/new"]);
    } finally {
      completeOlder({ repositories: [{ path: "D:/work/old" }] });
      await olderScan;
    }
    expect(await discoverWorkspaceRepositories("D:/work")).toEqual(["D:/work/new"]);
    expect(invoke).toHaveBeenCalledTimes(2);
  });
  test("preserves the containing repository before nested repositories", async () => {
    invoke.mockResolvedValue({
      repositories: [{ path: "D:/repo" }, { path: "D:/repo/packages/nested" }],
    });
    expect(await discoverWorkspaceRepositories("D:/repo/packages")).toEqual([
      "D:/repo", "D:/repo/packages/nested",
    ]);
  });
  test("uses shared Core repository discovery for multiple child repositories", async () => {
    invoke.mockResolvedValue({
      repositories: [{ path: "D:\\work\\service-b" }, { path: "D:\\work\\service-a" }],
    });

    const result = await discoverWorkspaceRepositories("D:/work");

    expect(invoke).toHaveBeenCalledWith("git_discover_workspace_repos", {
      workspacePath: "D:/work",
    });
    expect(readDirectory).not.toHaveBeenCalled();
    expect(result).toEqual(["D:/work/service-b", "D:/work/service-a"]);
  });

  test("strips Windows verbatim prefixes from discovered repository paths", async () => {
    invoke.mockResolvedValue({
      repositories: [
        { path: "\\\\?\\C:\\work\\repo" },
        { path: "//?/C:/work/repo/packages/nested" },
      ],
    });

    expect(await discoverWorkspaceRepositories("C:/work/repo")).toEqual([
      "C:/work/repo",
      "C:/work/repo/packages/nested",
    ]);
  });

  test("discovers repositories from every workspace root", async () => {
    invoke.mockImplementation(async (_command, args) => {
      const workspacePath = (args as { workspacePath: string }).workspacePath;
      return {
        repositories:
          workspacePath === "D:/work-a"
            ? [{ path: "D:/work-a/repo-a" }]
            : [{ path: "D:/work-b/repo-b" }],
      };
    });

    const result = await discoverWorkspaceRepositories(["D:/work-a", "D:/work-b"]);

    expect(invoke).toHaveBeenNthCalledWith(1, "git_discover_workspace_repos", {
      workspacePath: "D:/work-a",
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "git_discover_workspace_repos", {
      workspacePath: "D:/work-b",
    });
    expect(result).toEqual(["D:/work-a/repo-a", "D:/work-b/repo-b"]);
  });
});

describe("normalizeRepositoryPath", () => {
  test("preserves drive roots and remote schemes while collapsing separators", () => {
    expect(normalizeRepositoryPath("C://")).toBe("C:/");
    expect(normalizeRepositoryPath("remote://host/repo//src/")).toBe("remote://host/repo/src");
    expect(normalizeRepositoryPath("wsl://Ubuntu/repo//")).toBe("wsl://Ubuntu/repo");
    expect(normalizeRepositoryPath("/work//repo/")).toBe("/work/repo");
  });

  test("preserves verbatim and ordinary UNC roots", () => {
    expect(normalizeRepositoryPath("//?/unc/server/share//repo/")).toBe(
      "//server/share/repo",
    );
    expect(normalizeRepositoryPath("\\\\?\\UNC\\server\\share\\repo")).toBe(
      "//server/share/repo",
    );
    expect(normalizeRepositoryPath("\\\\server\\share\\repo")).toBe(
      "//server/share/repo",
    );
  });
});

describe("resolveRepositoryForFile", () => {
  test("returns relative file paths for a repository at a drive root", async () => {
    invoke.mockResolvedValue("X:/");
    expect(await resolveRepositoryForFile("X:/", "src/main.ts")).toEqual({
      repoPath: "X:/", filePath: "src/main.ts",
    });
    expect(invoke).toHaveBeenCalledWith("git_discover_repo", { path: "X:/src" });
  });

  test("falls back to a drive-root repository for a removed directory", async () => {
    invoke.mockRejectedValueOnce(new Error("Workspace does not exist"));
    invoke.mockResolvedValue("X:/");
    expect(await resolveRepositoryForFile("X:/", "removed/Deleted.java")).toEqual({
      repoPath: "X:/", filePath: "removed/Deleted.java",
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "git_discover_repo", { path: "X:/" });
  });

  test("discovers the repository from the file's directory", async () => {
    invoke.mockResolvedValue("D:/work/project");

    const result = await resolveRepositoryForFile("D:/work/project", "src/main.ts");

    expect(invoke).toHaveBeenCalledWith("git_discover_repo", {
      path: "D:/work/project/src",
    });
    expect(result).toEqual({
      repoPath: "D:/work/project",
      filePath: "src/main.ts",
    });
  });

  test("keeps absolute file paths relative to the discovered repository", async () => {
    invoke.mockResolvedValue("D:/work/project");

    const result = await resolveRepositoryForFile(
      "D:/work",
      "D:\\work\\project\\src\\main.ts",
    );

    expect(invoke).toHaveBeenCalledWith("git_discover_repo", {
      path: "D:/work/project/src",
    });
    expect(result).toEqual({
      repoPath: "D:/work/project",
      filePath: "src/main.ts",
    });
  });

  test("falls back to the active repository when a deleted file's directory is gone", async () => {
    invoke.mockImplementation(async (_command, args) => {
      const path = (args as { path: string }).path;
      if (path === "D:/work/project/removed/directory") {
        throw new Error("Workspace does not exist");
      }
      return "D:/work/project";
    });

    const result = await resolveRepositoryForFile(
      "D:/work/project",
      "removed/directory/Deleted.java",
    );

    expect(invoke).toHaveBeenNthCalledWith(1, "git_discover_repo", {
      path: "D:/work/project/removed/directory",
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "git_discover_repo", {
      path: "D:/work/project",
    });
    expect(result).toEqual({
      repoPath: "D:/work/project",
      filePath: "removed/directory/Deleted.java",
    });
  });
});
