import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { toast } from "sonner";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useRepositoryStore } from "../../stores/git-repository.store";
import type { GitReference } from "../../types/git.types";
import { GitLogToolWindow } from "./git-log-tool-window";

const dialogs = await import("@/ui/dialog");
const resize = await import("@/ui/resizable");
const controller = await import("../../hooks/use-git-log-controller");
const workspaceRefs = await import("../../hooks/use-git-workspace-references");
const diffs = await import("../../hooks/use-git-diff-actions");
const historyMutations = await import("../../hooks/use-git-history-mutations");
const pullWorkflow = await import("../../hooks/use-git-pull-workflow");
const branchApi = await import("../../api/git-branches-api");
const updates = await import("../../services/git-log-branch-update");
const tree = await import("./git-reference-tree");
const table = await import("./git-commit-table");
const inspector = await import("./git-commit-inspector");
const title = await import("./git-log-title-bar");
const reference: GitReference = {
  fullName: "refs/heads/topic",
  shortName: "topic",
  kind: "local",
  peelsToCommit: true,
  isCurrent: false,
  upstreamShortName: "origin/topic",
  behind: 0,
};
const refresh = mock(async () => {});
const confirm = mock(async () => true);
const checkout = mock(async (..._args: Parameters<typeof branchApi.checkoutGitReference>) => ({
  success: true,
  hasChanges: false,
  message: "Checked out",
}));
const pull = mock(async () => ({ status: "pulled" as const }));
const success = mock(() => "toast");
const pendingUpdates: Array<() => void> = [];
const operations: Promise<unknown>[] = [];
const update = mock((...args: Parameters<typeof updates.updateGitLogBranch>) => {
  const operation = new Promise<{ status: "branch-updated" }>((resolve) =>
    pendingUpdates.push(() => resolve({ status: "branch-updated" })),
  ).then(async (result) => {
    await args[2]();
    return result;
  });
  operations.push(operation);
  return operation;
});
const spies: Array<{ mockRestore: () => void }> = [];
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let previousRepos: ReturnType<typeof useRepositoryStore.getState>;
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
const content = ({ children }: { children?: ReactNode }) => <div>{children}</div>;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  previousRepos = useRepositoryStore.getState();
  useRepositoryStore.setState({ activeRepoPath: "C:/repo-a", availableRepoPaths: ["C:/repo-a"] });
  refresh.mockClear();
  confirm.mockClear();
  checkout.mockClear();
  update.mockClear();
  pull.mockClear();
  success.mockClear();
  // Keep the real action owner; stub unrelated data loading and rendering, so
  // this test exercises checkout confirmation and update dispatch without Git or layout timers.
  spies.push(
    spyOn(controller, "useGitLogController").mockImplementation(() => ({
      history: { references: [reference], recentReferences: [], commits: [], hasMore: false },
      repositoryCommits: [],
      loadState: "ready",
      error: null,
      selectedReference: reference,
      isLoadingMore: false,
      selectReference: () => {},
      forgetReference: () => {},
      refresh,
      loadMore: async () => {},
    })),
    spyOn(workspaceRefs, "useGitWorkspaceReferences").mockImplementation(() => ({
      referencesByRepository: new Map(),
      errorsByRepository: new Map(),
      isLoading: false,
      error: null,
      ensureRepository: async () => {},
      retryRepository: async () => {},
    })),
    spyOn(diffs, "useGitDiffActions").mockImplementation(
      (() => ({})) as unknown as typeof diffs.useGitDiffActions,
    ),
    spyOn(historyMutations, "useGitHistoryMutations").mockImplementation((() => ({
      isMutatingHistory: false,
      historyDialog: null,
    })) as unknown as typeof historyMutations.useGitHistoryMutations),
    spyOn(pullWorkflow, "useGitPullWorkflow").mockImplementation(() => ({
      isPulling: false,
      isPullLocked: false,
      pendingPreflight: null,
      pull,
    })),
    spyOn(dialogs, "showConfirmDialog").mockImplementation(confirm),
    spyOn(branchApi, "checkoutGitReference").mockImplementation(checkout),
    spyOn(updates, "updateGitLogBranch").mockImplementation(update),
    spyOn(resize, "ResizablePanelGroup").mockImplementation(content),
    spyOn(resize, "ResizablePanel").mockImplementation(content),
    spyOn(resize, "ResizableHandle").mockImplementation(() => <></>),
    spyOn(tree, "GitReferenceTree").mockImplementation(({ onReferenceAction, isMutating }) => (
      <div>
        <button
          data-action="checkout"
          disabled={isMutating}
          onClick={() => onReferenceAction("checkout", reference)}
        >
          Checkout
        </button>
        <button
          data-action="update"
          disabled={isMutating}
          onClick={() => onReferenceAction("update", reference)}
        >
          Update
        </button>
        <button
          data-action="checkout-tag"
          onClick={() =>
            onReferenceAction("checkout", {
              ...reference,
              fullName: "refs/tags/v1",
              shortName: "v1",
              kind: "tag",
            })
          }
        >
          Checkout Tag
        </button>
        <button
          data-action="rebase"
          onClick={() => onReferenceAction("checkoutAndRebase", reference)}
        >
          Checkout and Rebase
        </button>
      </div>
    )),
    spyOn(table, "GitCommitTable").mockImplementation(() => <></>),
    spyOn(inspector, "GitCommitInspector").mockImplementation(() => <></>),
    spyOn(title, "GitLogTitleBar").mockImplementation(() => <></>),
    spyOn(toast, "success").mockImplementation(success),
  );
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const resolve of pendingUpdates.splice(0)) resolve();
      await Promise.all(operations.splice(0));
    });
  } finally {
    for (const spy of spies.splice(0)) spy.mockRestore();
    useRepositoryStore.setState(previousRepos);
    container.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
const render = async () =>
  act(async () =>
    root.render(
      <LocaleProvider language="en-US">
        <GitLogToolWindow />
      </LocaleProvider>,
    ),
  );
const button = (action: string) =>
  container.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!;

test("Git Log Checkout starts directly without a second confirmation and refreshes afterwards", async () => {
  await render();
  await act(async () => button("checkout").click());
  expect(confirm).not.toHaveBeenCalled();
  expect(checkout.mock.calls).toEqual([["C:/repo-a", reference]]);
  expect(refresh).toHaveBeenCalledTimes(1);
});

test("Tag checkout and integration actions retain their confirmation flow", async () => {
  await render();
  confirm.mockImplementationOnce(async () => false);
  await act(async () => button("checkout-tag").click());
  confirm.mockImplementationOnce(async () => false);
  await act(async () => button("rebase").click());
  expect(confirm).toHaveBeenCalledTimes(2);
  expect(checkout).not.toHaveBeenCalled();
});

test("Update Selected starts the background update, keeps the Log and blocks repeated clicks", async () => {
  await render();
  await act(async () => {
    button("update").click();
    button("update").click();
  });
  expect(update).toHaveBeenCalledTimes(1);
  expect(pull).not.toHaveBeenCalled();
  expect(confirm).not.toHaveBeenCalled();
  expect(button("update").disabled).toBe(true);
  expect(container.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("Log");
  await act(async () => pendingUpdates.shift()!());
  expect(refresh).toHaveBeenCalledTimes(1);
  expect(button("update").disabled).toBe(false);
});

test("An old update cannot refresh a new repository or unlock its active operation", async () => {
  await render();
  await act(async () => button("update").click());
  const oldIsActive = update.mock.calls[0]![3]!;
  await act(async () =>
    useRepositoryStore.setState({ activeRepoPath: "C:/repo-b", availableRepoPaths: ["C:/repo-b"] }),
  );
  expect(oldIsActive()).toBe(false);
  await act(async () => button("update").click());
  await act(async () => pendingUpdates.shift()!());
  expect(refresh).not.toHaveBeenCalled();
  expect(success).not.toHaveBeenCalled();
  expect(button("update").disabled).toBe(true);
  await act(async () => pendingUpdates.shift()!());
  expect(refresh).toHaveBeenCalledTimes(1);
  expect(button("update").disabled).toBe(false);
});
