import { afterAll, beforeEach, expect, mock, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/git/rebase-session-v1.json";
import * as gitEvents from "../events/git-events";
import type { GitRebasePreview, GitRebaseSession } from "../types/git-rebase.types";
import { prepareGitRebasePlan } from "../utils/git-rebase-plan";

const emitGitChanged = spyOn(gitEvents, "emitGitChanged");
const invoke = mock(
  async (command: string, _args?: unknown): Promise<unknown> =>
    command === "git_discover_repo"
      ? "C:/repo"
      : { command: { exitCode: 0, warnings: [] }, session: fixture.sessionResponse },
);
mock.module("@/platform/tauri-core", () => ({ invoke }));
const { controlGitRebase, startGitRebase } = await import("./git-rebase-api");
beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
});
afterAll(() => emitGitChanged.mockRestore());

test("interactive rebase keeps the exact reviewed state and messages only for message actions", async () => {
  const preview = fixture.previewResponse as GitRebasePreview;
  await startGitRebase("C:/repo", preview, [
    { hash: preview.commits[0].hash, action: "edit", message: "Do not implicitly amend" },
    { hash: preview.commits[1].hash, action: "reword", message: "Title\n\nComplete body\n" },
  ]);
  expect(invoke).toHaveBeenLastCalledWith("git.rebaseStart", {
    root: "C:/repo",
    expectedState: preview.expectedState,
    steps: [
      { hash: preview.commits[0].hash, action: "edit" },
      { hash: preview.commits[1].hash, action: "reword", message: "Title\n\nComplete body\n" },
    ],
  });
});

test("continue never amends unless the user selects amend and preserves the durable session result", async () => {
  const sessionId = fixture.sessionResponse.sessionId;
  const result = await controlGitRebase("C:/repo", sessionId, "continue");
  expect(invoke).toHaveBeenLastCalledWith("git.rebaseControl", {
    root: "C:/repo",
    sessionId,
    action: "continue",
  });
  expect(result.session).toEqual(fixture.sessionResponse as GitRebaseSession);
  await controlGitRebase(
    "C:/repo",
    sessionId,
    "continue",
    "Amended\n\nFull body",
    fixture.sessionResponse.head,
  );
  expect(invoke).toHaveBeenLastCalledWith("git.rebaseControl", {
    root: "C:/repo",
    sessionId,
    action: "continue",
    amendMessage: "Amended\n\nFull body",
    expectedHead: fixture.sessionResponse.head,
  });
  expect(emitGitChanged).toHaveBeenLastCalledWith({
    repoPath: "C:/repo",
    scopes: ["working-tree", "history", "refs"],
    source: "interactive-rebase",
  });
});

test("squash previews stay out of the payload unless the user edits the final message", async () => {
  const preview = fixture.previewResponse as GitRebasePreview;
  const [first, second] = preview.commits;
  const plan = prepareGitRebasePlan(
    [
      { hash: first.hash, action: "edit" },
      { hash: second.hash, action: "squash" },
    ],
    preview.commits,
  );
  expect(plan.messages.get(second.hash)).toBe(
    `${first.message.replace(/\n+$/, "")}\n\n${second.message}`,
  );
  await startGitRebase("C:/repo", preview, plan.steps);
  expect(invoke).toHaveBeenLastCalledWith("git.rebaseStart", {
    root: "C:/repo",
    expectedState: preview.expectedState,
    steps: [
      { hash: first.hash, action: "edit" },
      { hash: second.hash, action: "squash" },
    ],
  });
  const edited = prepareGitRebasePlan(
    [
      { hash: first.hash, action: "edit" },
      { hash: second.hash, action: "squash", message: "Reviewed final title\n\nFull final body\n" },
    ],
    preview.commits,
  );
  await startGitRebase("C:/repo", preview, edited.steps);
  expect(invoke).toHaveBeenLastCalledWith("git.rebaseStart", {
    root: "C:/repo",
    expectedState: preview.expectedState,
    steps: [
      { hash: first.hash, action: "edit" },
      { hash: second.hash, action: "squash", message: "Reviewed final title\n\nFull final body\n" },
    ],
  });
});
