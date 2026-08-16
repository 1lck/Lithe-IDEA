import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (_command: string, _args?: unknown): Promise<string | null> => null);

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { clearRepositoryDiscoveryCache, resolveRepositoryForFile } = await import("./git-repo-api");

beforeEach(() => {
  invoke.mockReset();
  clearRepositoryDiscoveryCache();
});

describe("resolveRepositoryForFile", () => {
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
});
