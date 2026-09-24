import { describe, expect, test } from "bun:test";
import { generateCommitDraft, type CommitDraftState } from "./ai-commit-workflow";

const files = [{ path: "a.ts", changeKind: "modified", diff: "+evidence" }];
function scenario(message = "") {
  const state: CommitDraftState = { selection: "repo:selection", message };
  const controller = new AbortController();
  const applied: string[] = [];
  const deps = {
    readFiles: async () => files,
    generate: async () => "Generated",
    current: () => state,
    confirmReplace: async () => true,
    apply: (message: string) => {
      applied.push(message);
    },
    signal: controller.signal,
  };
  return { state, controller, applied, deps };
}
describe("AI commit draft workflow", () => {
  test("fills an empty draft without confirmation", async () => {
    const s = scenario();
    s.deps.confirmReplace = async () => {
      throw new Error("unexpected confirmation");
    };
    expect(await generateCommitDraft(s.deps)).toBe("applied");
    expect(s.applied).toEqual(["Generated"]);
  });
  test("keeps existing text when replacement is declined", async () => {
    const s = scenario("My draft");
    s.deps.confirmReplace = async () => false;
    expect(await generateCommitDraft(s.deps)).toBe("kept");
    expect(s.applied).toEqual([]);
  });
  test("requires confirmation for text typed during generation", async () => {
    const s = scenario();
    s.deps.generate = async () => {
      s.state.message = "Typed while waiting";
      return "Generated";
    };
    s.deps.confirmReplace = async () => false;
    expect(await generateCommitDraft(s.deps)).toBe("kept");
    expect(s.applied).toEqual([]);
  });
  test("rejects workspace changes before generation completes", async () => {
    const s = scenario();
    s.deps.generate = async () => {
      s.state.selection = "another repo";
      return "Old";
    };
    await expect(generateCommitDraft(s.deps)).rejects.toThrow("AI_COMMIT_STALE");
    expect(s.applied).toEqual([]);
  });
  test("rejects changed patch even when selected filenames stay the same", async () => {
    const s = scenario();
    let reads = 0;
    s.deps.readFiles = async () =>
      ++reads === 1 ? files : [{ ...files[0], diff: "+new content" }];
    await expect(generateCommitDraft(s.deps)).rejects.toThrow("AI_COMMIT_STALE");
    expect(s.applied).toEqual([]);
  });
  test("preserves edits made while confirmation was open", async () => {
    const s = scenario("Original");
    s.deps.confirmReplace = async () => {
      s.state.message = "Edited";
      return true;
    };
    await expect(generateCommitDraft(s.deps)).rejects.toThrow("AI_COMMIT_DRAFT_CHANGED");
    expect(s.applied).toEqual([]);
  });
  test("cancellation never applies returned text", async () => {
    const s = scenario();
    s.deps.generate = async () => {
      s.controller.abort();
      return "Cancelled";
    };
    await expect(generateCommitDraft(s.deps)).rejects.toThrow();
    expect(s.applied).toEqual([]);
  });
});
