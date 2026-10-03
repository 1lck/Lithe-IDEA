import type { WorkspaceCommitPathScope } from "../types/git-workspace-commit.types";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import GitCommitPanel from "./git-commit-panel";
import type { GitFile } from "../types/git.types";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let currentMessage = "";
let selectedFiles: GitFile[] = [];
let scope: WorkspaceCommitPathScope | undefined;
let scopeError: string | undefined;

beforeEach(() => {
  registry.resetForTests();
  registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  currentMessage = "";
  scope = undefined;
  scopeError = undefined;
});

afterEach(async () => {
  await act(async () => root.unmount());
  // bun runs test files in one process: restore the shared workspace stores so the
  // panel's draft owner does not leak into later files (pull dialog and
  // workspace-commit assertions read them).
  const commitStore = useWorkspaceCommitStore.getStore("A").getState();
  commitStore.setDraftOwner(null);
  commitStore.workflow.setState({ busy: false, session: null, review: null, error: null });
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

interface RenderOptions {
  message?: string;
  files?: GitFile[];
}

// Mirror the real owner: commit message updates re-render the panel with the
// next draft. This is also the exact callback the textarea onChange invokes.
const applyMessage = (message: string) => {
  currentMessage = message;
  rerender();
};

const rerender = () => {
  root.render(
    <LocaleProvider language="en-US">
      <GitCommitPanel
        pathScope={scope}
        commitScopeError={scopeError}
        selectedFiles={selectedFiles}
        workspacePath="C:/workspace/A"
        repositoryPaths={["C:/workspace/A"]}
        commitMessage={currentMessage}
        onCommitMessageChange={applyMessage}
        repoPath="C:/workspace/A"
        currentBranch="main"
      />
    </LocaleProvider>,
  );
};

const renderPanel = async (options: RenderOptions = {}) => {
  currentMessage = options.message ?? "";
  selectedFiles = options.files ?? [stagedFile];
  await act(async () => rerender());
};

const buttonByText = (text: string) =>
  Array.from(container.querySelectorAll("button")).find((button) => button.textContent === text);
const commitButton = () => buttonByText("Commit");

test("the legend counts untracked as added and renames as modified, like IntelliJ", async () => {
  const file = (path: string, status: GitFile["status"]): GitFile => ({
    ...stagedFile,
    path,
    repositoryRelativePath: path,
    status,
  });
  await renderPanel({
    files: [
      file("a.ts", "added"),
      file("b.ts", "untracked"),
      file("c.ts", "modified"),
      file("d.ts", "renamed"),
      file("e.ts", "deleted"),
    ],
  });
  const legend = container.querySelector('[data-testid="git-commit-legend"]');
  expect(Array.from(legend?.children ?? []).map((chunk) => chunk.textContent)).toEqual([
    "1+1 added",
    "2 modified",
    "1 deleted",
  ]);
});

test("the legend is hidden when no file is selected", async () => {
  await renderPanel({ files: [] });
  expect(container.querySelector('[data-testid="git-commit-legend"]')).toBeNull();
});

test("a commit starts a regular commit, never an amend", async () => {
  await renderPanel({ message: "Plain commit" });
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    await act(async () => commitButton()!.click());
    expect(prepare).toHaveBeenCalledTimes(1);
    const request = prepare.mock.calls[0][0];
    expect(request.amend).toBe(false);
    expect(request.message).toBe("Plain commit");
    expect(container.querySelector('[aria-label="Amend"]')).toBeNull();
  } finally {
    prepare.mockRestore();
  }
});

test("Commit stays enabled and explains what is missing, like IntelliJ", async () => {
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    await renderPanel({ files: [] });
    expect(commitButton()?.disabled).toBe(false);
    expect(buttonByText("Commit and Push...")?.disabled).toBe(false);

    await act(async () => commitButton()!.click());
    const hint = () => container.querySelector('[data-testid="git-commit-hint"]')?.textContent;
    expect(hint()).toBe("Select files to commit and specify commit message");
    expect(prepare).not.toHaveBeenCalled();

    // Typing a message clears that half of the hint; the missing selection remains.
    await act(async () => applyMessage("Ready"));
    expect(hint()).toBe("Select files to commit");
  } finally {
    prepare.mockRestore();
  }
});

test("Commit with files but no message asks for a commit message", async () => {
  await renderPanel();
  await act(async () => commitButton()!.click());
  expect(container.querySelector('[data-testid="git-commit-hint"]')?.textContent).toBe(
    "Specify commit message",
  );
  await act(async () => applyMessage("Done"));
  expect(container.querySelector('[data-testid="git-commit-hint"]')).toBeNull();
});

test("the commit button and shortcut cannot bypass another changelist's staged files", async () => {
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    scopeError = "Other changelists contain staged changes.";
    await renderPanel({ message: "Feature" });
    expect(commitButton()?.disabled).toBe(true);
    expect(container.textContent).toContain(scopeError);
    await act(async () =>
      container
        .querySelector("textarea")!
        .dispatchEvent(
          new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true }),
        ),
    );
    expect(prepare).not.toHaveBeenCalled();
  } finally {
    prepare.mockRestore();
  }
});

test("commit captures the active list scope for native revalidation", async () => {
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    scope = { include: false, paths: { ".": ["application.yaml"] } };
    await renderPanel({ message: "Feature" });
    await act(async () => commitButton()!.click());
    expect(prepare.mock.calls[0]?.[0].pathScope).toEqual(scope);
  } finally {
    prepare.mockRestore();
  }
});
