import { expect, spyOn, test } from "bun:test";
import * as core from "@/core/lithe-core-client";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { fffListFiles, searchFilesContent } from "./file-search-api";

test("multi-root inventory and scoped search carry the complete ownership context", async () => {
  const roots = ["C:/main", "C:/main/nested"];
  const requests: Array<{ command: string; payload: Record<string, unknown> }> = [];
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({
    revision: 1,
    excludedDirectories: {},
    gitIgnoreFailed: false,
  });
  const execute = spyOn(core, "executeCore").mockImplementation(
    async <T, P = unknown>(request: core.CoreRequest<P>) => {
      requests.push({
        command: request.command,
        payload: request.payload as Record<string, unknown>,
      });
      const parent = (request.payload as Record<string, unknown>).root === roots[0];
      const data =
        request.command === "workspace.snapshot"
          ? { files: parent ? ["Main.java"] : ["Visible.java"] }
          : {
              matches: [
                {
                  kind: "content",
                  path: parent ? "Main.java" : "Visible.java",
                  line: 1,
                  preview: "needle",
                },
              ],
            };
      return { id: request.id, ok: true as const, data: data as T };
    },
  );
  try {
    const inventory = await fffListFiles(roots);
    expect(inventory.map((file) => file.path.replace(/\\/g, "/"))).toEqual([
      "C:/main/Main.java",
      "C:/main/nested/Visible.java",
    ]);
    expect(
      requests.every(
        (request) => JSON.stringify(request.payload.workspaceRoots) === JSON.stringify(roots),
      ),
    ).toBe(true);
    requests.length = 0;
    const result = await searchFilesContent({
      root_paths: roots,
      scope_paths: ["C:/main"],
      query: "needle",
    });
    expect(result.results).toHaveLength(2);
    expect(requests.map((request) => request.payload.scopePaths)).toEqual([["."], ["."]]);
    expect(
      requests.every(
        (request) => JSON.stringify(request.payload.workspaceRoots) === JSON.stringify(roots),
      ),
    ).toBe(true);
    requests.length = 0;
    await searchFilesContent({
      root_paths: roots,
      scope_paths: ["C:/main/nested/src"],
      query: "needle",
    });
    expect(requests.map((request) => request.payload.scopePaths)).toEqual([
      ["nested/src"],
      ["src"],
    ]);
  } finally {
    execute.mockRestore();
    configure.mockRestore();
  }
});
