import { expect, spyOn, test } from "bun:test";
import * as core from "@/core/lithe-core-client";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import {
  DEFAULT_HIDDEN_DIRECTORY_PATTERNS,
  DEFAULT_HIDDEN_FILE_PATTERNS,
} from "@/features/settings/config/default-settings";
import { fffListFiles, searchFileNames, searchFilesContent } from "./file-search-api";
import { mergeSearchResults } from "@/features/global-search/utils/content-search-results";

test("continues a Core content cursor and keeps same-file ranges across pages", async () => {
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({ revision: 1, excludedDirectories: {}, gitIgnoreFailed: false });
  const requests: Array<core.CoreRequest> = [];
  const execute = spyOn(core, "executeCore").mockImplementation(async <T, P = unknown>(request: core.CoreRequest<P>) => {
    requests.push(request);
    const cursor = (request.payload as { cursor: string | null }).cursor;
    const data = cursor === null
      ? { matches: [{ kind: "content", path: "src/a.ts", line: 1, preview: "x", sourceLine: "  😀foo", contentMatchRanges: [{ start: 4, length: 3 }] }], nextCursor: "page-2" }
      : { matches: [{ kind: "content", path: "src/a.ts", line: 2, preview: "x", sourceLine: "foo", contentMatchRanges: [{ start: 0, length: 3 }] }], nextCursor: null };
    return { id: request.id, ok: true as const, data: data as T };
  });
  try {
    const input = { root_paths: ["C:/main"], query: "foo", max_results: 1,
      include_patterns: ["src/**"], exclude_patterns: ["test"], filter_root: "C:/main" };
    const first = await searchFilesContent(input);
    const second = await searchFilesContent({ ...input, file_offset: first.next_file_offset });
    expect(first.has_more).toBe(true);
    expect(second.has_more).toBe(false);
    const merged = mergeSearchResults(first.results, second.results);
    expect(merged).toHaveLength(1);
    expect(merged[0]?.matches.map((match) => [match.line_number, match.line_content, match.column_start, match.column_end]))
      .toEqual([[1, "  😀foo", 4, 7], [2, "foo", 0, 3]]);
    expect(requests[0]?.payload).toEqual(expect.objectContaining({
      includePathPatterns: ["src/**"], excludePathPatterns: ["test"], includeContentRanges: true,
    }));
    expect(requests[1]?.payload).toEqual(expect.objectContaining({ cursor: "page-2" }));
  } finally { execute.mockRestore(); configure.mockRestore(); }
});

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
    expect(result.results).toHaveLength(1);
    expect(result.has_more).toBe(true);
    const next = await searchFilesContent({
      root_paths: roots, scope_paths: ["C:/main"], query: "needle", file_offset: result.next_file_offset,
    });
    expect(next.results).toHaveLength(1);
    expect(next.has_more).toBe(false);
    expect(requests.map((request) => request.payload.scopePaths)).toEqual([["."], ["."]]);
    expect(
      requests.every(
        (request) => JSON.stringify(request.payload.workspaceRoots) === JSON.stringify(roots),
      ),
    ).toBe(true);
    requests.length = 0;
    const scoped = await searchFilesContent({
      root_paths: roots,
      scope_paths: ["C:/main/nested/src"],
      query: "needle",
    });
    await searchFilesContent({
      root_paths: roots, scope_paths: ["C:/main/nested/src"], query: "needle", file_offset: scoped.next_file_offset,
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


test("workspace file listing asks Core for flat files without allocating a tree", async () => {
  const root = "C:/work/project";
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({
    revision: 1, excludedDirectories: {}, gitIgnoreFailed: false,
  });
  const requests: Array<core.CoreRequest> = [];
  const execute = spyOn(core, "executeCore").mockImplementation(async <T, P = unknown>(request: core.CoreRequest<P>) => {
    requests.push(request);
    return {id: request.id, ok: true as const, data: {files: ["src/a.ts", "src/b.ts"]} as T};
  });
  try {
    const files = await fffListFiles([root]);
    expect(files.map((file) => file.relative_path)).toEqual(["src/a.ts", "src/b.ts"]);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.command).toBe("workspace.snapshot");
    // The user's hidden-path settings travel with the request; Core adds and interprets the built-ins.
    expect(requests[0]?.payload).toEqual({
      root,
      workspaceRoots: [root],
      includeTree: false,
      hiddenDirectoryNames: [...DEFAULT_HIDDEN_DIRECTORY_PATTERNS],
      hiddenFilePatterns: [...DEFAULT_HIDDEN_FILE_PATTERNS],
    });
  } finally {
    execute.mockRestore(); configure.mockRestore();
  }
});

test("file-name search asks Core's index for files only, with relative context and hidden rules", async () => {
  const root = "C:/work/project";
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({
    revision: 1, excludedDirectories: {}, gitIgnoreFailed: false,
  });
  const requests: Array<core.CoreRequest> = [];
  const execute = spyOn(core, "executeCore").mockImplementation(async <T, P = unknown>(request: core.CoreRequest<P>) => {
    requests.push(request);
    return {id: request.id, ok: true as const, data: {matches: [
      {kind: "file", path: "src/a.ts", line: null, preview: "", matchingDegree: 2048},
      {kind: "file", path: "src/b.ts", line: null, preview: "", matchingDegree: 1024},
    ]} as T};
  });
  try {
    const hits = await searchFileNames("a", [root], 50, undefined, {
      openPaths: ["C:/work/project/src/a.ts", "D:/elsewhere/x.ts"],
      recentPaths: ["C:\\work\\project\\src\\b.ts"],
    });
    expect(hits.map((hit) => [hit.relative_path, hit.score])).toEqual([
      ["src/a.ts", 2048],
      ["src/b.ts", 1024],
    ]);
    expect(requests).toHaveLength(1);
    expect(requests[0]?.command).toBe("workspace.searchEverywhere");
    expect(requests[0]?.payload).toMatchObject({
      root,
      query: "a",
      resultKinds: ["file"],
      maxFileResults: 50,
      maxSymbolResults: 0,
      maxContentResults: 0,
      context: {openPaths: ["src/a.ts"], recentPaths: ["src/b.ts"]},
      hiddenDirectoryNames: [...DEFAULT_HIDDEN_DIRECTORY_PATTERNS],
    });
  } finally {
    execute.mockRestore(); configure.mockRestore();
  }
});
