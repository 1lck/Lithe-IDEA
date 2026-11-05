import { describe, expect, test } from "bun:test";
import fixture from "../../../../shared/fixtures/git/graph-projection-v1.json";
import {
  geometryFreeProjection,
  linearChainProjection,
  normalizeGraphRequest,
  stubGitGraphProjection,
} from "./git-graph-projection-stub";

const cases = fixture.cases as unknown as Array<{
  name: string;
  request: Record<string, unknown>;
  response: ReturnType<typeof stubGitGraphProjection>;
}>;

describe("git.graphProjection test stub", () => {
  for (const testCase of cases) {
    test(`answers ${testCase.name} with Core's recorded response`, () => {
      expect(stubGitGraphProjection(testCase.request)).toBe(testCase.response);
    });
  }

  test("geometry-free rows, labels and ancestry match Core for every fixture case", () => {
    for (const testCase of cases) {
      const request = normalizeGraphRequest(testCase.request);
      // A repository context reorders the scoped rows; that is Core's rule.
      if (request.repositoryCommits.length > 0) continue;
      const actual = geometryFreeProjection(request);
      expect(
        actual.rows.map((row) => [row.commitHash, row.labels]),
        testCase.name,
      ).toEqual(testCase.response.rows.map((row) => [row.commitHash, row.labels]));
      expect(actual.currentBranchHashes, testCase.name).toEqual(
        testCase.response.currentBranchHashes,
      );
    }
  });

  test("projects a linear chain exactly as Core does", () => {
    const linear = cases.filter(
      (testCase) => linearChainProjection(normalizeGraphRequest(testCase.request)) !== null,
    );
    expect(linear.length).toBeGreaterThan(0);
    for (const testCase of linear) {
      expect(linearChainProjection(normalizeGraphRequest(testCase.request))).toEqual(
        testCase.response,
      );
    }
  });

  test("refuses a history it cannot answer, unless geometry is not asserted", () => {
    const request = {
      commits: [{ hash: "m", parentHashes: ["a", "b"] }, { hash: "a" }, { hash: "b" }],
    };
    expect(() => stubGitGraphProjection(request)).toThrow("not in the shared fixture");
    const rows = stubGitGraphProjection(request, { geometryFree: true }).rows;
    expect(rows.map((row) => row.commitHash)).toEqual(["m", "a", "b"]);
    expect(rows.every((row) => row.printElements.length === 0)).toBe(true);
  });
});
