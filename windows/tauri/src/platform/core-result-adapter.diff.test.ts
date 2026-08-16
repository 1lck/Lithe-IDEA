import { describe, expect, test } from "bun:test";
import { adaptCoreResult } from "./core-result-adapter";

const twoFilePatch = `diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1,2 @@
 hello
+world
diff --git a/b.txt b/b.txt
index 333..444 100644
--- a/b.txt
+++ b/b.txt
@@ -1 +0,0 @@
-old line
`;

describe("git diff stats adaptation", () => {
  test("maps per-file additions and deletions from the whole tree patch", () => {
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work" },
      { patch: twoFilePatch },
    );

    expect(stats).toEqual([
      { file_path: "a.txt", staged: false, additions: 1, deletions: 0 },
      { file_path: "b.txt", staged: false, additions: 0, deletions: 1 },
    ]);
  });

  test("carries the staged flag from the request into every stat entry", () => {
    const stats = adaptCoreResult(
      "git_status_diff_stats",
      { repoPath: "C:/work", staged: true },
      { patch: twoFilePatch },
    );

    expect(Array.isArray(stats)).toBe(true);
    for (const stat of stats as Array<{ staged: boolean }>) {
      expect(stat.staged).toBe(true);
    }
  });
});

describe("git single-file diff adaptation", () => {
  test("returns the parsed diff for the requested file", () => {
    const diff = adaptCoreResult(
      "git_diff_file",
      { repoPath: "C:/work", filePath: "a.txt" },
      { patch: twoFilePatch },
    );

    expect((diff as { file_path: string }).file_path).toBe("a.txt");
  });
});
