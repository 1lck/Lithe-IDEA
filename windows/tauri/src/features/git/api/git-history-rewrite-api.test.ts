import { afterAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/git/history-rewrite-v1.json";
import * as gitEvents from "../events/git-events";
import type {
  GitHistoryRewritePreview,
  GitHistoryRewriteResult,
} from "../types/git-history-rewrite.types";

const preview = fixture.preview as GitHistoryRewritePreview;
let result: GitHistoryRewriteResult;
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");
const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.historyRewritePreview") return preview;
  if (command === "git.write") return result;
  return null;
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
const { executeGitHistoryRewrite, getGitHistoryRewritePreview } =
  await import("./git-history-rewrite-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
  result = {
    exitCode: 0,
    historyRewrite: fixture.historyRewrite as NonNullable<
      GitHistoryRewriteResult["historyRewrite"]
    >,
    warnings: [],
  };
});
afterAll(() => emitGitChanged.mockRestore());

describe("Reviewed Git history mutations", () => {
  test("uses the reviewed snapshot and complete message without silently replacing either", async () => {
    const reviewed = await getGitHistoryRewritePreview(
      "C:/repo",
      "editCommitMessage",
      ["selected"],
      "review-operation",
    );
    const message = "Updated title\n\nBody with a second paragraph.\n\nFinal paragraph.\n";
    await executeGitHistoryRewrite("C:/repo", reviewed, message);
    expect(invoke.mock.calls.filter(([command]) => command === "git.write")).toEqual([
      [
        "git.write",
        {
          root: "C:/repo",
          operation: "editCommitMessage",
          revision: preview.selectedCommits[0].hash,
          message,
          expectedState: fixture.preview.expectedState,
        },
      ],
    ]);
    expect(
      invoke.mock.calls.filter(([command]) => command === "git.historyRewritePreview"),
    ).toHaveLength(1);
  });

  test("blocked previews cannot execute Git writes", async () => {
    await expect(
      executeGitHistoryRewrite("C:/repo", {
        ...preview,
        allowed: false,
        blockers: [{ code: "published", message: "Published history is protected" }],
        expectedState: null,
      }),
    ).rejects.toThrow("Published history is protected");
    expect(invoke.mock.calls.some(([command]) => command === "git.write")).toBe(false);
  });

  test("retains recovery and warnings after a partial failure and refreshes the originating repository", async () => {
    result = {
      ...result,
      exitCode: 1,
      operationError: { code: "process_failed", message: "Refresh failed" },
      warnings: [{ code: "recovery_available", message: "Previous HEAD is preserved" }],
      historyRewrite: { ...result.historyRewrite!, worktreeRefresh: "failed" },
    };
    expect(await executeGitHistoryRewrite("C:/repo", preview, "Updated")).toEqual(result);
    expect(emitGitChanged).toHaveBeenLastCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs"],
      source: "history-rewrite",
    });
  });
});
