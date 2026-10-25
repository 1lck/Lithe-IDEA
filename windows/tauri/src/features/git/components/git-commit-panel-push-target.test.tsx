import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import type { GitFile } from "../types/git.types";

// The destination question is a portal dialog, which only mounts when the UI
// modules are loaded after the DOM exists. The panel is therefore imported inside
// each test instead of at the top, like the other dialog tests in this folder.
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;

beforeEach(() => {
  registry.resetForTests();
  registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  const commitStore = useWorkspaceCommitStore.getStore("A").getState();
  commitStore.setDraftOwner(null);
  commitStore.workflow.setState({
    busy: false,
    session: null,
    review: null,
    pushTargetPrompt: null,
    error: null,
  });
  container.remove();
  restoreDom();
  registry.resetForTests();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

const stagedFile: GitFile = {
  path: "src/hello.ts",
  repositoryPath: "C:/workspace/A",
  repositoryRelativePath: "src/hello.ts",
  status: "modified",
  staged: true,
  canToggleStaging: true,
};

const question = {
  repositoryId: ".",
  localBranch: "feature/topic",
  remote: "origin",
  upstream: "origin/main",
  upstreamBranch: "main",
};

const renderPanelWithQuestion = async () => {
  const { default: GitCommitPanel } = await import("./git-commit-panel");
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  await act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitCommitPanel
          selectedFiles={[stagedFile]}
          workspacePath="C:/workspace/A"
          repositoryPaths={["C:/workspace/A"]}
          commitMessage="Ship it"
          onCommitMessageChange={() => {}}
          repoPath="C:/workspace/A"
          currentBranch="main"
        />
      </LocaleProvider>,
    ),
  );
  // Core raised this before writing any commit; the panel only presents it.
  await act(async () =>
    workflow.setState({
      pushTargetPrompt: {
        request: {
          repositories: [{ id: ".", root: "C:/workspace/A" }],
          message: "Ship it",
          amend: false,
          push: true,
          includeParentReferences: true,
        },
        questions: [question],
        confirmed: false,
        forceReview: false,
      },
    }),
  );
  return workflow;
};

const byTestId = (testId: string) =>
  document.querySelector(`[data-testid="${testId}"]`) as HTMLButtonElement | null;
const buttonByText = (text: string) =>
  Array.from(document.querySelectorAll("button")).find((button) => button.textContent === text);

test("a destination question from Core is answered in the panel and sent back to the workflow", async () => {
  const workflow = await renderPanelWithQuestion();
  const answer = spyOn(workflow, "answerPushTargets").mockResolvedValue(undefined);
  try {
    // Nothing else may start while the question is open.
    expect(buttonByText("Commit")?.disabled).toBe(true);
    expect(byTestId("git-push-target-confirm")?.disabled).toBe(true);
    await act(async () => byTestId("git-push-target-upstream-.")!.click());
    await act(async () => byTestId("git-push-target-confirm")!.click());
    expect(answer).toHaveBeenCalledWith({
      ".": { choice: "upstream", remote: "origin", remoteBranch: "main" },
    });
  } finally {
    answer.mockRestore();
  }
});

test("cancelling the destination question closes it without starting a commit", async () => {
  const workflow = await renderPanelWithQuestion();
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    await act(async () => buttonByText("Cancel")!.click());
    expect(workflow.getState().pushTargetPrompt).toBeNull();
    expect(prepare).not.toHaveBeenCalled();
    expect(buttonByText("Commit")?.disabled).toBe(false);
  } finally {
    prepare.mockRestore();
  }
});
