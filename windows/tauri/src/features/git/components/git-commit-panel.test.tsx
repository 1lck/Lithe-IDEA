import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry as registry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import * as commitsApi from "../api/git-commits-api";
import { useGitStore } from "../stores/git.store";
import GitCommitPanel from "./git-commit-panel";
import type { GitCommit, GitFile } from "../types/git.types";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let messageChanges: string[] = [];
let currentMessage = "";
let selectedFiles: GitFile[] = [];
const HEAD_MESSAGE = "Previous commit title\n\nPrevious commit body";
const getHeadCommitMessage = mock(async (_repoPath: string): Promise<string | null> => HEAD_MESSAGE);
let headMessageSpy: { mockRestore: () => void };

beforeEach(() => {
  registry.resetForTests();
  registry.activateWorkspace({ id: "A", name: "A" }, "ready");
  restoreDom = installHappyDom();
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  messageChanges = [];
  currentMessage = "";
  getHeadCommitMessage.mockReset().mockResolvedValue(HEAD_MESSAGE);
  headMessageSpy = spyOn(commitsApi, "getHeadCommitMessage").mockImplementation(
    getHeadCommitMessage,
  );
});

afterEach(async () => {
  await act(async () => root.unmount());
  headMessageSpy.mockRestore();
  // bun runs test files in one process: restore the shared workspace stores
  // so the seeded HEAD commit and the panel's draft owner do not leak into
  // later files (pull dialog and workspace-commit assertions read them).
  useGitStore.getStore("A").setState({ commits: [] });
  const commitStore = useWorkspaceCommitStore.getStore("A").getState();
  commitStore.setDraftOwner(null);
  commitStore.workflow.setState({ busy: false, session: null, review: null, error: null });
  container.remove();
  restoreDom();
  registry.resetForTests();
  if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
});

// `git log --all` lists the newest commit of any reference first; amend must
// never take its message from that list.
const otherBranchCommit: GitCommit = {
  hash: "fedcba0987654321",
  shortHash: "fedcba0",
  parentHashes: [],
  message: "Newest commit on another branch",
  author: "Lithe Tester",
  date: "2026-01-02T00:00:00Z",
  decorations: "origin/main",
};

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
  /** Active repository; staged files may belong to another repository of the workspace. */
  repoPath?: string;
  repositoryPaths?: string[];
}

// Mirror the real owner: commit message updates re-render the panel with the
// next draft, so uncheck-restore comparisons see the applied amend message.
// This is also the exact callback the textarea onChange invokes.
const applyMessage = (message: string) => {
  messageChanges.push(message);
  currentMessage = message;
  rerender();
};

let activeRepoPath = "C:/workspace/A";
let repositoryPaths = ["C:/workspace/A"];

const rerender = () => {
  root.render(
    <LocaleProvider language="en-US">
      <GitCommitPanel
        selectedFiles={selectedFiles}
        workspacePath="C:/workspace/A"
        repositoryPaths={repositoryPaths}
        commitMessage={currentMessage}
        onCommitMessageChange={applyMessage}
        repoPath={activeRepoPath}
        currentBranch="main"
      />
    </LocaleProvider>,
  );
};

const renderPanel = async (options: RenderOptions = {}) => {
  useGitStore.getStore("A").setState({ commits: [otherBranchCommit] });
  currentMessage = options.message ?? "";
  selectedFiles = options.files ?? [stagedFile];
  activeRepoPath = options.repoPath ?? "C:/workspace/A";
  repositoryPaths = options.repositoryPaths ?? ["C:/workspace/A"];
  await act(async () => rerender());
};

const amendCheckbox = () => container.querySelector<HTMLElement>('[aria-label="Amend"]');

// happy-dom forwards a click on the label-wrapped checkbox button twice (the
// direct click plus label activation), which toggles the box back off. Browsers
// deduplicate that, so drive a single activation with the keyboard here.
const toggleAmend = async () => {
  const checkbox = amendCheckbox()!;
  await act(async () => {
    checkbox.focus();
    checkbox.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
    checkbox.dispatchEvent(new KeyboardEvent("keyup", { key: " ", bubbles: true }));
  });
};

const buttonByText = (text: string) =>
  Array.from(container.querySelectorAll("button")).find((button) => button.textContent === text);
const commitButton = () => buttonByText("Commit") ?? buttonByText("Amend Commit");

test("checking amend with an untouched draft loads the HEAD commit message", async () => {
  await renderPanel();
  const checkbox = amendCheckbox();
  expect(checkbox).not.toBeNull();
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual(["Previous commit title\n\nPrevious commit body"]);
  expect(commitButton()?.textContent).toBe("Amend Commit");
});

test("checking amend keeps a user-typed draft untouched", async () => {
  await renderPanel({ message: "My own draft" });
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([]);
  expect(commitButton()?.textContent).toBe("Amend Commit");
});

test("unchecking amend restores the replaced draft while the loaded message is untouched", async () => {
  await renderPanel();
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual(["Previous commit title\n\nPrevious commit body"]);

  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([
    "Previous commit title\n\nPrevious commit body",
    "",
  ]);
  expect(commitButton()?.textContent).toBe("Commit");
});

test("unchecking amend keeps the draft after the user edited the loaded message", async () => {
  await renderPanel();
  await act(async () => toggleAmend());
  // Drive the edit through the same onCommitMessageChange callback the textarea
  // onChange uses: happy-dom does not deliver synthetic textarea input events
  // to React's controlled-value tracker, so DOM-level editing is not observable.
  await act(async () => applyMessage("Edited amend message"));
  expect(messageChanges).toEqual([
    "Previous commit title\n\nPrevious commit body",
    "Edited amend message",
  ]);

  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([
    "Previous commit title\n\nPrevious commit body",
    "Edited amend message",
  ]);
  expect(commitButton()?.textContent).toBe("Commit");
});

test("amend reads the HEAD message instead of the newest listed commit", async () => {
  await renderPanel();
  await act(async () => toggleAmend());
  expect(getHeadCommitMessage).toHaveBeenCalledWith("C:/workspace/A");
  expect(messageChanges).toEqual([HEAD_MESSAGE]);
});

test("amend stays off and explains why when HEAD has no commit", async () => {
  getHeadCommitMessage.mockResolvedValue(null);
  await renderPanel();
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([]);
  expect(commitButton()?.textContent).toBe("Commit");
  expect(container.textContent).toContain("There is no commit to amend yet.");
});

test("amend disables Commit and Push because the rewrite would need a force push", async () => {
  await renderPanel({ message: "Ready to commit" });
  expect(buttonByText("Commit and Push...")?.disabled).toBe(false);
  await act(async () => toggleAmend());
  expect(buttonByText("Commit and Push...")?.disabled).toBe(true);
});

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

test("commit forwards the amend flag to the workspace commit workflow", async () => {
  await renderPanel();
  const workflow = useWorkspaceCommitStore.getStore("A").getState().workflow;
  const prepare = spyOn(workflow, "prepare").mockResolvedValue(undefined);
  try {
    await act(async () => toggleAmend());
    await act(async () => commitButton()!.click());
    expect(prepare).toHaveBeenCalledTimes(1);
    const request = prepare.mock.calls[0][0];
    expect(request.amend).toBe(true);
    expect(request.message).toBe("Previous commit title\n\nPrevious commit body");
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

const stagedFileInB: GitFile = {
  ...stagedFile,
  path: "src/b.ts",
  repositoryPath: "C:/workspace/B",
  repositoryRelativePath: "src/b.ts",
};
const MESSAGE_A = "Message of A";
const MESSAGE_B = "Message of B";
const headMessageByRepository = (messages: Record<string, string | null>) =>
  getHeadCommitMessage.mockImplementation(async (repo: string) => messages[repo] ?? null);

test("amend reads HEAD from the repository that has the staged files, not the active one", async () => {
  headMessageByRepository({ "C:/workspace/A": MESSAGE_A, "C:/workspace/B": MESSAGE_B });
  await renderPanel({
    files: [stagedFileInB],
    repoPath: "C:/workspace/A",
    repositoryPaths: ["C:/workspace/A", "C:/workspace/B"],
  });
  await act(async () => toggleAmend());
  expect(getHeadCommitMessage).toHaveBeenCalledTimes(1);
  expect(getHeadCommitMessage).toHaveBeenCalledWith("C:/workspace/B");
  expect(messageChanges).toEqual([MESSAGE_B]);
});

test("amend loads the staged repository's message when the active repository has no commit", async () => {
  headMessageByRepository({ "C:/workspace/A": null, "C:/workspace/B": MESSAGE_B });
  await renderPanel({
    files: [stagedFileInB],
    repoPath: "C:/workspace/A",
    repositoryPaths: ["C:/workspace/A", "C:/workspace/B"],
  });
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([MESSAGE_B]);
  expect(container.textContent).not.toContain("There is no commit to amend yet.");
});

test("amend is unavailable while several repositories have staged files", async () => {
  await renderPanel({
    files: [stagedFile, stagedFileInB],
    repoPath: "C:/workspace/A",
    repositoryPaths: ["C:/workspace/A", "C:/workspace/B"],
  });
  expect(amendCheckbox()?.hasAttribute("data-disabled")).toBe(true);
  await act(async () => toggleAmend());
  expect(getHeadCommitMessage).not.toHaveBeenCalled();
  expect(messageChanges).toEqual([]);
});

test("staging another repository after checking amend drops the loaded message", async () => {
  headMessageByRepository({ "C:/workspace/A": MESSAGE_A, "C:/workspace/B": MESSAGE_B });
  const repositories = ["C:/workspace/A", "C:/workspace/B"];
  await renderPanel({ files: [stagedFile], repositoryPaths: repositories });
  await act(async () => toggleAmend());
  expect(messageChanges).toEqual([MESSAGE_A]);
  expect(commitButton()?.textContent).toBe("Amend Commit");

  // Staging a file of B means a commit would rewrite both A and B.
  selectedFiles = [stagedFile, stagedFileInB];
  await act(async () => rerender());
  expect(messageChanges).toEqual([MESSAGE_A, ""]);
  expect(commitButton()?.textContent).toBe("Commit");
});
