import { expect, spyOn, test } from "bun:test";
import * as core from "@/core/lithe-core-client";
import * as files from "@/features/file-system/controllers/file-operations";
import { searchProviderFilesContent } from "./provider-content-search";

test("provider search batches host-read snapshots through Core before paging", async () => {
  const read = spyOn(files, "readFileContent").mockImplementation(async (path) =>
    path.endsWith("a.ts") ? "😀 foo" : "no match",
  );
  const execute = spyOn(core, "executeCore").mockImplementation(
    async <T, P = unknown>(request: core.CoreRequest<P>) => {
      expect(request.command).toBe("workspace.searchTextBatch");
      expect(request.payload).toEqual(
        expect.objectContaining({
          query: "foo",
          wholeWords: true,
          regularExpression: false,
          files: [
            { path: "wsl://dev/src/a.ts", text: "😀 foo" },
            { path: "wsl://dev/src/b.ts", text: "no match" },
          ],
        }),
      );
      return {
        id: request.id,
        ok: true as const,
        data: {
          files: [
            {
              path: "wsl://dev/src/a.ts",
              matches: [
                {
                  line: 1,
                  lineText: "😀 foo",
                  ranges: [{ start: 3, length: 3 }],
                  contextBefore: [],
                  contextAfter: [],
                },
              ],
            },
          ],
        } as T,
      };
    },
  );
  try {
    const result = await searchProviderFilesContent({
      files: [
        { name: "a.ts", path: "wsl://dev/src/a.ts", isDir: false },
        { name: "b.ts", path: "wsl://dev/src/b.ts", isDir: false },
        { name: "skip.ts", path: "wsl://dev/test/skip.ts", isDir: false },
      ],
      query: "foo",
      rootFolderPath: "wsl://dev",
      options: { caseSensitive: false, wholeWord: true, useRegex: false },
      maxResults: 10,
      fileOffset: 0,
      contextLines: 2,
      includeQuery: "src/",
      excludeQuery: "test/",
      isCancelled: () => false,
    });
    expect(result?.results[0]?.matches[0]).toEqual(
      expect.objectContaining({
        line_content: "😀 foo",
        column_start: 3,
        column_end: 6,
        match_ranges: [{ start: 3, end: 6 }],
      }),
    );
    expect(read).toHaveBeenCalledTimes(2);
    expect(execute).toHaveBeenCalledTimes(1);
  } finally {
    read.mockRestore();
    execute.mockRestore();
  }
});

test("provider search excludes snapshots above the Core byte limit", async () => {
  const read = spyOn(files, "readFileContent").mockResolvedValue("😀".repeat(524_289));
  const execute = spyOn(core, "executeCore").mockImplementation(
    async <T, P = unknown>(request: core.CoreRequest<P>) => {
      expect(request.payload).toEqual(expect.objectContaining({ files: [] }));
      return { id: request.id, ok: true as const, data: { files: [] } as T };
    },
  );
  try {
    const result = await searchProviderFilesContent({
      files: [{ name: "large.txt", path: "wsl://dev/large.txt", isDir: false }],
      query: "foo",
      rootFolderPath: "wsl://dev",
      options: { caseSensitive: false, wholeWord: false, useRegex: false },
      maxResults: 10,
      fileOffset: 0,
      contextLines: 0,
      includeQuery: "",
      excludeQuery: "",
      isCancelled: () => false,
    });
    expect(result?.results).toEqual([]);
    expect(result?.has_more).toBe(false);
    expect(execute).toHaveBeenCalledTimes(1);
  } finally {
    read.mockRestore();
    execute.mockRestore();
  }
});
