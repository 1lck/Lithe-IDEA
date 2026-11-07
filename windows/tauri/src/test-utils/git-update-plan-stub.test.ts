import { describe, expect, test } from "bun:test";
import fixture from "../../../../shared/fixtures/git/update-plan-v1.json";
import { stubGitUpdatePlan } from "./git-update-plan-stub";

describe("git.updatePlan test stub", () => {
  for (const testCase of fixture.cases) {
    test(testCase.name, () => {
      expect(stubGitUpdatePlan(testCase.request as Record<string, unknown>)).toEqual(
        testCase.plan as never,
      );
    });
  }
});
