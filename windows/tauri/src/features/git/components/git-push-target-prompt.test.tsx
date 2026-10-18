import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { GitPushPreview, GitPushTargetChoice } from "../types/git.types";

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

const divergentPreview: GitPushPreview = {
  localBranch: "feature/topic",
  localHead: "2222222222222222222222222222222222222222",
  remote: "origin",
  remoteBranch: "feature/topic",
  targetKind: "divergent",
  createsRemoteBranch: true,
  remoteTrackingOid: null,
  upstream: "origin/main",
  tags: [],
  commits: [],
  hasMore: false,
};

async function renderPrompt(onChoose: (choice: GitPushTargetChoice) => void, onCancel: () => void) {
  const { GitPushTargetPrompt } = await import("./git-push-target-prompt");
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitPushTargetPrompt preview={divergentPreview} onChoose={onChoose} onCancel={onCancel} />
      </LocaleProvider>,
    ),
  );
}

const clickByTestId = async (testId: string) => {
  const button = document.querySelector(`[data-testid="${testId}"]`);
  expect(button).not.toBeNull();
  await act(async () => (button as HTMLButtonElement).click());
};

test("names both destinations instead of pushing to an unrelated branch", async () => {
  await renderPrompt(
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

test("reports the confirmed destination", async () => {
  const choices: GitPushTargetChoice[] = [];
  await renderPrompt(
    (choice) => {
      choices.push(choice);
    },
    () => {},
  );
  await clickByTestId("git-push-target-prompt-publish");
  expect(choices).toEqual(["publish"]);
});

test("keeps the divergent upstream when the user chooses it", async () => {
  const choices: GitPushTargetChoice[] = [];
  await renderPrompt(
    (choice) => {
      choices.push(choice);
    },
    () => {},
  );
  await clickByTestId("git-push-target-prompt-upstream");
  expect(choices).toEqual(["upstream"]);
});
