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
});
