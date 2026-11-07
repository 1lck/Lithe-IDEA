import { describe, expect, test } from "bun:test";
import fixture from "../../../../shared/fixtures/git/history-window-v1.json";
import { stubGitHistoryWindow } from "./git-history-window-stub";

describe("git.historyWindow test stub", () => {
  for (const testCase of fixture.cases) {
    test(testCase.name, () => {
      expect(stubGitHistoryWindow(testCase.request as Record<string, unknown>)).toEqual(
        testCase.response,
      );
    });
  }
});
