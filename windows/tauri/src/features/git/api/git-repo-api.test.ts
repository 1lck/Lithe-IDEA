import { beforeEach, describe, expect, mock, test } from "bun:test";

import pathCases from "../../../../../../shared/fixtures/git/windows-paths.json";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);
const readDirectory = mock(async (_path: string): Promise<unknown[]> => []);

// Spread the real modules so each override stays scoped to a single export;
// a partial mock would strip the sibling exports (Channel, createDirectory, …)
// for every other test sharing this module registry.
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));
const platformModule = await import("@/features/file-system/controllers/platform");
mock.module("@/features/file-system/controllers/platform", () => ({
  ...platformModule,
  readDirectory,
}));

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
  test("uses Core ownership for an absolute file in another checkout", async () => {
    invoke.mockResolvedValue({ root: "D:/work/other", path: "src/main.ts", ownership: "git" });
    expect(await resolveRepositoryForFile("D:/work/project", "D:/work/other/src/main.ts")).toEqual({
      repoPath: "D:/work/other", filePath: "src/main.ts",
    });
    expect(invoke).toHaveBeenCalledWith("git.resolveFileContext", {
      root: "D:/work/project", path: "D:/work/other/src/main.ts",
    });
  });
  test("keeps deleted paths resolved by Core without falling back to the active checkout", async () => {
    invoke.mockResolvedValue({ root: "X:/nested", path: "removed/Deleted.java", ownership: "git" });
    expect(await resolveRepositoryForFile("X:/", "nested/removed/Deleted.java")).toEqual({
      repoPath: "X:/nested", filePath: "removed/Deleted.java",
    });
    expect(invoke).toHaveBeenCalledTimes(1);
  });
  test("reports unowned paths and propagates discovery failures", async () => {
    invoke.mockResolvedValueOnce(null).mockRejectedValueOnce(new Error("discovery failed"));
    expect(await resolveRepositoryForFile("C:/repo", "file.ts")).toBeNull();
    await expect(resolveRepositoryForFile("C:/repo", "file.ts")).rejects.toThrow("discovery failed");
  });
  test("shares only concurrent file lookups and rechecks later", async () => {
    let complete!: (value: unknown) => void;
    invoke.mockImplementationOnce(() => new Promise((resolve) => { complete = resolve; }));
    const first = resolveRepositoryForFile("C:/repo", "file.ts");
    const second = resolveRepositoryForFile("C:/repo", "file.ts");
    try {
      expect(invoke).toHaveBeenCalledTimes(1);
    } finally {
      complete({ root: "C:/repo", path: "file.ts", ownership: "git" });
    }
    expect(await first).toEqual(await second);
    invoke.mockResolvedValue({ root: "C:/repo/nested", path: "file.ts", ownership: "git" });
    expect(await resolveRepositoryForFile("C:/repo", "file.ts")).toEqual({ repoPath: "C:/repo/nested", filePath: "file.ts" });
    expect(invoke).toHaveBeenCalledTimes(2);
  });
  test("rejects an invalid ownership response", async () => {
    invoke.mockResolvedValue({ root: "C:/repo", path: "file.ts", ownership: "other" });
    await expect(resolveRepositoryForFile("C:/repo", "file.ts")).rejects.toThrow("Invalid Git file context");
  });
});


describe("Windows Git path identity", () => {
  for (const { input, normalized } of pathCases.accepted) {
    test(`normalizes supported path ${JSON.stringify(input)}`, () => {
      expect(normalizeRepositoryPath(input)).toBe(normalized);
    });
  }
  for (const input of pathCases.rejected) {
    test(`rejects unsupported path ${JSON.stringify(input)} before discovery`, async () => {
      expect(normalizeRepositoryPath(input)).toBe(input);
      await expect(resolveRepositoryForFile("C:/work", input)).rejects.toThrow("Git does not support Windows paths");
      expect(invoke).not.toHaveBeenCalled();
    });
  }
  for (const [input, root, directory] of [
    [String.raw`\\server\share\repo\src\main.ts`, "//server/share/repo", "//server/share/repo/src"],
    [String.raw`\\?\C:\work\repo\src\main.ts`, "C:/work/repo", "C:/work/repo/src"],
    [String.raw`\\?\UNC\server\share\repo\src\main.ts`, "//server/share/repo", "//server/share/repo/src"],
    [String.raw`\\?\C:\src\main.ts`, "C:/", "C:/src"],
    ["remote://host/repo/src/main.ts", "remote://host/repo", "remote://host/repo/src"],
    ["wsl://Ubuntu/repo/src/main.ts", "wsl://Ubuntu/repo", "wsl://Ubuntu/repo/src"],
  ]) {
    test(`resolves an absolute file without prepending the active repository: ${input}`, async () => {
      const remote = input!.startsWith("remote://") || input!.startsWith("wsl://");
      invoke.mockResolvedValue(remote ? root : { root, path: "src/main.ts", ownership: "git" });
      expect(await resolveRepositoryForFile("D:/different-repository", input!)).toEqual({
        repoPath: root, filePath: "src/main.ts",
      });
      if (remote) expect(invoke).toHaveBeenCalledWith("git_discover_repo", { path: directory });
      else expect(invoke).toHaveBeenCalledWith("git.resolveFileContext", { root: "D:/different-repository", path: normalizeRepositoryPath(input!) });
    });
  }
  test("does not hide an unsupported Core response with the deleted-directory fallback", async () => {
    invoke.mockResolvedValueOnce({ root: String.raw`\\?\C:\work\repo.`, path: "src/main.ts", ownership: "git" });
    await expect(resolveRepositoryForFile("C:/work/repo", "src/main.ts")).rejects.toThrow("Git does not support Windows paths");
    expect(invoke).toHaveBeenCalledTimes(1);
  });
  test("rejects trailing dots in relative filenames before looking up their parent", async () => {
    await expect(resolveRepositoryForFile("C:/work/repo", "src/main.ts.")).rejects.toThrow("Git does not support Windows paths");
    expect(invoke).not.toHaveBeenCalled();
  });
  test("retains POSIX names in remote and WSL repositories", () => {
    expect(normalizeRepositoryPath("remote://host/repo./file ")).toBe("remote://host/repo./file ");
    expect(normalizeRepositoryPath("wsl://Ubuntu/repo./file ")).toBe("wsl://Ubuntu/repo./file ");
  });
});
