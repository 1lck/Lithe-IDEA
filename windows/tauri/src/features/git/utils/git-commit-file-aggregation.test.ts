import { describe, expect, test } from "bun:test";
import type { GitCommit } from "../types/git.types";
import { aggregateGitCommitFiles } from "./git-commit-file-aggregation";

const commit = (hash: string): GitCommit => ({
  hash,
  shortHash: hash,
  message: hash,
  author: "Lithe Test",
  date: "2026-08-31T00:00:00Z",
  parentHashes: [],
  decorations: "",
});

describe("Git commit file aggregation", () => {
  test("merges selected commits by path and keeps the newest matching commit", () => {
    const newest = commit("newest");
    const oldest = commit("oldest");
    const result = aggregateGitCommitFiles([
      {
        commit: newest,
        files: [
          { path: "src/shared.ts", status: "M" },
          { path: "src/z.ts", status: "A" },
        ],
      },
      {
        commit: oldest,
        files: [
          { path: "src/a.ts", status: "A" },
          { path: "src/shared.ts", status: "A" },
        ],
      },
    ]);

    expect(result.files).toEqual([
      { path: "src/a.ts", status: "A" },
      { path: "src/shared.ts", status: "M" },
      { path: "src/z.ts", status: "A" },
    ]);
    expect(result.commitByPath.get("src/shared.ts")).toBe(newest);
    expect(result.commitByPath.get("src/a.ts")).toBe(oldest);
  });
});
