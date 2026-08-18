import { describe, expect, test } from "bun:test";
import type { FileEntry } from "../types/app.types";
import { loadFolderExpansion } from "./file-tree-utils";

const directory = (name: string, path: string, children?: FileEntry[]): FileEntry => ({
  name,
  path,
  isDir: true,
  children,
});

describe("compact folder expansion", () => {
  test("loads and expands a single-child directory chain in one action", async () => {
    const entries = new Map<string, FileEntry[]>([
      ["/a", [directory("b", "/a/b")]],
      ["/a/b", [directory("c", "/a/b/c")]],
      ["/a/b/c", [{ name: "file.ts", path: "/a/b/c/file.ts", isDir: false }]],
    ]);

    const result = await loadFolderExpansion(
      [directory("a", "/a")],
      "/a",
      true,
      async (path) => entries.get(path) ?? [],
    );

    expect(result.expandedPaths).toEqual(["/a", "/a/b", "/a/b/c"]);
    expect(result.finalPath).toBe("/a/b/c");
  });

  test("stops at a branch and keeps non-compact expansion to one level", async () => {
    const entries = new Map<string, FileEntry[]>([
      ["/a", [directory("b", "/a/b")]],
      ["/a/b", [directory("c", "/a/b/c"), directory("d", "/a/b/d")]],
    ]);
    const readChildren = async (path: string) => entries.get(path) ?? [];

    const compact = await loadFolderExpansion([directory("a", "/a")], "/a", true, readChildren);
    const regular = await loadFolderExpansion([directory("a", "/a")], "/a", false, readChildren);

    expect(compact.expandedPaths).toEqual(["/a", "/a/b"]);
    expect(regular.expandedPaths).toEqual(["/a"]);
  });
});
