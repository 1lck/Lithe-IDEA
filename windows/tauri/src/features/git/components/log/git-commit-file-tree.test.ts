import { describe, expect, test } from "bun:test";
import { buildPathTree } from "@/features/sidebar/lib/path-tree";
import type { GitCommitFile } from "../../types/git.types";
import { countCommitFileTreeLeaves } from "./git-commit-file-tree";

describe("GitCommitFileTree", () => {
  test("counts every descendant file in a nested directory", () => {
    const files: GitCommitFile[] = [
      { path: "src/a.ts", status: "M" },
      { path: "src/nested/b.ts", status: "A" },
      { path: "src/nested/deeper/c.ts", status: "D" },
    ];
    const [root] = buildPathTree(files, {
      getPath: (file) => file.path,
      getKey: (file) => file.path,
    });

    expect(root?.type).toBe("branch");
    expect(root ? countCommitFileTreeLeaves(root) : 0).toBe(3);
  });

  test("keeps the trailing count/status from stealing width from file names", async () => {
    const css = await Bun.file(
      new URL("../../../file-explorer/styles/file-explorer-tree.css", import.meta.url),
    ).text();
    const source = await Bun.file(new URL("./git-commit-file-tree.tsx", import.meta.url)).text();

    expect(source).toContain("file-tree-container git-commit-file-tree");
    expect(css).toMatch(
      /\.file-tree-container\.git-commit-file-tree \.file-tree-row > span:last-child \{\s*flex: 0 0 auto;/,
    );
  });
});
