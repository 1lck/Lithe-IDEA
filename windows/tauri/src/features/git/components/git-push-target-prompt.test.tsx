import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import type {
  WorkspaceCommitPushTarget,
  WorkspaceCommitPushTargetQuestion,
} from "../types/git-workspace-commit.types";

let restoreDom: () => void;
let root: Root;
let container: HTMLDivElement;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  restoreDom();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

const question = (
  repositoryId: string,
  overrides: Partial<WorkspaceCommitPushTargetQuestion> = {},
): WorkspaceCommitPushTargetQuestion => ({
  repositoryId,
  localBranch: "feature/topic",
  remote: "origin",
  upstream: "origin/main",
  upstreamBranch: "main",
  ...overrides,
});

async function renderPrompt(
  questions: WorkspaceCommitPushTargetQuestion[],
  onConfirm: (answers: Record<string, WorkspaceCommitPushTarget>) => void,
  onCancel: () => void,
) {
  const { GitPushTargetPrompt } = await import("./git-push-target-prompt");
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitPushTargetPrompt questions={questions} onConfirm={onConfirm} onCancel={onCancel} />
      </LocaleProvider>,
    ),
  );
}

const byTestId = (testId: string) => {
  const element = document.querySelector(`[data-testid="${testId}"]`);
  expect(element).not.toBeNull();
  return element as HTMLButtonElement;
};
const click = async (testId: string) => act(async () => byTestId(testId).click());

test("names both destinations instead of pushing to an unrelated branch", async () => {
  await renderPrompt(
    [question(".")],
    () => {},
    () => {},
  );
  const text = document.body.textContent ?? "";
  // The warning names the branch it diverges from, and both buttons spell out
  // where the push would actually land.
  expect(text).toContain("origin/main");
  expect(text).toContain("Publish to origin/feature/topic");
  expect(text).toContain("Push to origin/main");
});

test("cannot be confirmed until every repository has an answer", async () => {
  const answers: Record<string, WorkspaceCommitPushTarget>[] = [];
  await renderPrompt(
    [question("."), question("B")],
    (next) => answers.push(next),
    () => {},
  );
  expect(byTestId("git-push-target-confirm").disabled).toBe(true);
  await click("git-push-target-publish-.");
  expect(byTestId("git-push-target-confirm").disabled).toBe(true);
  await click("git-push-target-upstream-B");
  expect(byTestId("git-push-target-confirm").disabled).toBe(false);
  await click("git-push-target-confirm");
  expect(answers).toEqual([
    {
      ".": { choice: "publish", remote: "origin", remoteBranch: "feature/topic" },
      B: { choice: "upstream", remote: "origin", remoteBranch: "main" },
    },
  ]);
});

test("binds an upstream answer to the upstream's own slashed branch name", async () => {
  const answers: Record<string, WorkspaceCommitPushTarget>[] = [];
  await renderPrompt(
    [
      question(".", {
        remote: "team/origin",
        upstream: "team/origin/team/release",
        upstreamBranch: "team/release",
      }),
    ],
    (next) => answers.push(next),
    () => {},
  );
  await click("git-push-target-upstream-.");
  await click("git-push-target-confirm");
  expect(answers[0]).toEqual({
    ".": { choice: "upstream", remote: "team/origin", remoteBranch: "team/release" },
  });
});

test("the last pick wins and cancelling reports nothing", async () => {
  const answers: Record<string, WorkspaceCommitPushTarget>[] = [];
  let cancelled = 0;
  await renderPrompt(
    [question(".")],
    (next) => answers.push(next),
    () => (cancelled += 1),
  );
  await click("git-push-target-upstream-.");
  await click("git-push-target-publish-.");
  expect(byTestId("git-push-target-publish-.").getAttribute("aria-pressed")).toBe("true");
  expect(byTestId("git-push-target-upstream-.").getAttribute("aria-pressed")).toBe("false");
  const cancel = Array.from(document.querySelectorAll("button")).find(
    (button) => button.textContent === "Cancel",
  )!;
  await act(async () => cancel.click());
  expect(cancelled).toBe(1);
  expect(answers).toEqual([]);
});
