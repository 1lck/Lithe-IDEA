import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/git/repository-colors-v1.json";
import { GIT_REPOSITORY_COLOR_PALETTE, loadRepositoryColors } from "./git-repository-colors";

describe("Git repository color presentation", () => {
  test("uses Core slots from the shared full ordered workspace fixture", async () => {
    const entry = fixture.cases.find((item) => item.name === "full order includes hidden worktree")!;
    const calls: unknown[] = [];
    const result = await loadRepositoryColors(entry.request.repositoryIds, async (request) => {
      calls.push(request);
      return entry.expected;
    });
    expect(calls).toEqual([entry.request]);
    expect(result?.colors.get("/work/lib")).toBe(GIT_REPOSITORY_COLOR_PALETTE[2]);
    expect(result?.fallback).toBe(GIT_REPOSITORY_COLOR_PALETTE[0]);
    expect(result?.showColors).toBe(true);
  });

  test("requests bounded pages and uses Core's global slot at the page boundary", async () => {
    const roots = Array.from({ length: 129 }, (_, index) => `C:/repo-${index}`);
    const requests: { offset: number; totalCount: number; repositoryIds: string[] }[] = [];
    const result = await loadRepositoryColors(roots, async (request) => {
      requests.push(request);
      return {
        assignments: request.repositoryIds.map((id) => ({ id, slot: request.offset === 0 ? 3 : 6 })),
        fallbackSlot: 2,
        showColors: true,
      };
    });
    expect(requests.map((request) => [request.offset, request.repositoryIds.length])).toEqual([[0, 128], [128, 1]]);
    expect(result?.colors.get("C:/repo-0")).toBe(GIT_REPOSITORY_COLOR_PALETTE[3]);
    expect(result?.colors.get("C:/repo-128")).toBe(GIT_REPOSITORY_COLOR_PALETTE[6]);
    expect(result?.fallback).toBe(GIT_REPOSITORY_COLOR_PALETTE[2]);
  });

  test("drops an in-flight response after the owning view changes", async () => {
    let finish!: (page: { assignments: { id: string; slot: number }[]; fallbackSlot: number; showColors: boolean }) => void;
    let current = true;
    const pending = loadRepositoryColors(["C:/repo"], () => new Promise((resolve) => { finish = resolve; }), () => current);
    current = false;
    finish({ assignments: [{ id: "C:/repo", slot: 0 }], fallbackSlot: 0, showColors: false });
    expect(await pending).toBeNull();
  });

  test("rejects mismatched Core identities instead of assigning another repository's color", async () => {
    await expect(loadRepositoryColors(["C:/repo"], async () => ({
      assignments: [{ id: "C:/other", slot: 0 }], fallbackSlot: 0, showColors: false,
    }))).rejects.toThrow("Invalid Core repository color page");
  });
});
