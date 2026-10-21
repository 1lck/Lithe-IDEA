import { describe, expect, test } from "bun:test";
import { buildPathTree } from "@/features/sidebar/lib/path-tree";
import { compareGitFileNames } from "./natural-file-name-compare";

describe("compareGitFileNames", () => {
  test("orders embedded numbers by numeric value like intellij-community", () => {
    expect(compareGitFileNames("file2", "file10")).toBeLessThan(0);
    expect(compareGitFileNames("file9", "file10")).toBeLessThan(0);
    expect(compareGitFileNames("file10", "file9")).toBeGreaterThan(0);
    expect(compareGitFileNames("v1", "v2")).toBeLessThan(0);
    expect(compareGitFileNames("v2", "v10")).toBeLessThan(0);
  });

  test("ignores case first and breaks ties case-sensitively", () => {
    expect(compareGitFileNames("a.txt", "B.txt")).toBeLessThan(0);
    expect(compareGitFileNames("Readme.md", "readme.md")).toBeLessThan(0);
    expect(compareGitFileNames("readme.md", "Readme.md")).toBeGreaterThan(0);
    expect(compareGitFileNames("same.txt", "same.txt")).toBe(0);
  });

  test("ranks '-' and '_' alike, falling back to code order", () => {
    expect(compareGitFileNames("a-b", "a_b")).toBeLessThan(0);
    expect(compareGitFileNames("a_b", "a-b")).toBeGreaterThan(0);
    expect(compareGitFileNames("a-b", "a.b")).toBeGreaterThan(0);
  });

  test("keeps shorter zero padding after the equal numeric value", () => {
    expect(compareGitFileNames("file7", "file07")).toBeLessThan(0);
    expect(compareGitFileNames("file07", "file7")).toBeGreaterThan(0);
    expect(compareGitFileNames("file 1", "file 01")).toBeLessThan(0);
  });

  test("compares text after a shared numeric segment", () => {
    expect(compareGitFileNames("a1b", "a1c")).toBeLessThan(0);
    expect(compareGitFileNames("1st-pass", "2nd-pass")).toBeLessThan(0);
  });

  test("shorter strings sort first when prefixes match", () => {
    expect(compareGitFileNames("file", "file1")).toBeLessThan(0);
    expect(compareGitFileNames("", "a")).toBeLessThan(0);
  });
});

describe("buildPathTree with compareGitFileNames", () => {
  test("keeps directories first and orders siblings naturally", () => {
    const files = [
      "src/file10.ts",
      "src/file2.ts",
      "docs/readme.md",
      "README.md",
      "app.ts",
    ];
    const nodes = buildPathTree(
      files.map((path) => ({ path })),
      {
        getKey: (file) => file.path,
        getPath: (file) => file.path,
        compareNames: compareGitFileNames,
      },
    );

    expect(nodes.map((node) => node.name)).toEqual([
      "docs",
      "src",
      "app.ts",
      "README.md",
    ]);
    expect(nodes[1].children.map((node) => node.name)).toEqual(["file2.ts", "file10.ts"]);
  });
});
