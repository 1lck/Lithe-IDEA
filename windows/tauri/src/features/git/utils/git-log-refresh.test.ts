import { describe, expect, test } from "bun:test";
import { shouldRefreshGitLogForChange } from "./git-log-refresh";

describe("Git Log refresh events", () => {
  test("refreshes for history, refs, and repository changes", () => {
    const repoPath = "C:/work/project";

    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["history"] }, repoPath)).toBe(true);
    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["refs"] }, repoPath)).toBe(true);
    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["repository"] }, repoPath)).toBe(true);
  });

  test("ignores working-tree-only and unrelated repository changes", () => {
    const repoPath = "C:/work/project";

    expect(shouldRefreshGitLogForChange({ repoPath, scopes: ["working-tree"] }, repoPath)).toBe(
      false,
    );
    expect(
      shouldRefreshGitLogForChange(
        { repoPath: "C:/work/other", scopes: ["history"] },
        repoPath,
      ),
    ).toBe(false);
  });

  test("refreshes conservatively when an event has no scopes", () => {
    expect(shouldRefreshGitLogForChange({ repoPath: "C:/work/project" }, "C:/work/project")).toBe(
      true,
    );
  });
});
