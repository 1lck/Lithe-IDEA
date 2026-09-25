import { beforeEach, describe, expect, mock, test } from "bun:test";

const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git_blame_file") return { lines: [] };
  throw new Error(`Unexpected command: ${command}`);
});

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { getResolvedGitBlame } = await import("./git-blame-api");
const { clearRepositoryDiscoveryCache } = await import("./git-repo-api");

beforeEach(() => {
  invoke.mockClear();
  clearRepositoryDiscoveryCache();
});

describe("getResolvedGitBlame", () => {
  test("uses the canonical repoPath field for the blame request", async () => {
    await getResolvedGitBlame("C:/repo", "src/main.ts", "blame-1");

    expect(invoke.mock.calls).toEqual([
      ["git_discover_repo", { path: "C:/repo/src" }],
      [
        "git_blame_file",
        {
          repoPath: "C:/repo",
          filePath: "src/main.ts",
          operationId: "blame-1",
        },
      ],
    ]);
  });
});
