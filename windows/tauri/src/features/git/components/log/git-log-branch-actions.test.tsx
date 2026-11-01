import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { toast } from "sonner";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useRepositoryStore } from "../../stores/git-repository.store";
import { useGitLogPreferencesStore } from "../../stores/git-log-preferences.store";
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
const notifications = await import("@/ui/idea-notification");
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
const remoteReference: GitReference = {
  ...reference,
  fullName: "refs/remotes/upstream/preview",
  shortName: "upstream/preview",
  kind: "remote",
  upstreamShortName: undefined,
};
const trackingRemote: GitReference = {
  ...remoteReference,
  fullName: "refs/remotes/origin/topic",
  shortName: "origin/topic",
};
const refresh = mock(async () => {});
const confirm = mock(async () => true);
const checkout = mock(async (..._args: Parameters<typeof branchApi.checkoutGitReference>) => ({
  success: true,
  hasChanges: false,
  // Match the real Checkout API: successful results have no display message.
  message: "",
}));
const pull = mock(async () => ({ status: "pulled" as const }));
const success = mock(() => "toast");
const failure = mock((..._args: Parameters<typeof toast.error>) => "toast");
const warning = mock((..._args: Parameters<typeof toast.warning>) => "toast");
type NotificationCard = Parameters<typeof notifications.showIdeaNotification>[0];
const notificationsShown: NotificationCard[] = [];
const deleteLocal = mock(
  async (..._args: Parameters<typeof branchApi.deleteLocalBranch>) => ({
    name: "topic",
    deletedTarget: "abc123def456",
  }),
);
const restoreDeleted = mock(
  async (..._args: Parameters<typeof branchApi.restoreDeletedBranch>) => {},
);
const setTracking = mock(
  async (..._args: Parameters<typeof branchApi.setBranchUpstream>) => {},
);
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
// The tool window persists the applied Branch filter per repository; restore the shared
// preferences store so randomized suite order cannot leak this file's references.
let previousGitLogPreferences: ReturnType<typeof useGitLogPreferencesStore.getState>;
const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
const content = ({ children }: { children?: ReactNode }) => <div>{children}</div>;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  globals.IS_REACT_ACT_ENVIRONMENT = true;
  previousRepos = useRepositoryStore.getState();
  previousGitLogPreferences = useGitLogPreferencesStore.getState();
  useRepositoryStore.setState({ activeRepoPath: "C:/repo-a", availableRepoPaths: ["C:/repo-a"] });
  refresh.mockClear();
  confirm.mockClear();
  checkout.mockClear();
  update.mockClear();
  pull.mockClear();
  success.mockClear();
  failure.mockClear();
  warning.mockClear();
  deleteLocal.mockClear();
  restoreDeleted.mockClear();
  setTracking.mockClear();
  notificationsShown.length = 0;
  // Keep the real action owner; stub unrelated data loading and rendering, so
  // this test exercises checkout confirmation and update dispatch without Git or layout timers.
  spies.push(
    spyOn(controller, "useGitLogController").mockImplementation(() => ({
      history: {
        references: [reference, trackingRemote],
        recentReferences: [],
        commits: [],
        hasMore: false,
      },
      repositoryCommits: [],
      loadState: "ready",
      error: null,
      selectedReference: reference,
      isLoadingMore: false,
      selectReference: () => {},
      forgetReference: () => {},
      refresh,
      loadMore: async () => false,
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
    spyOn(branchApi, "deleteLocalBranch").mockImplementation(deleteLocal),
    spyOn(branchApi, "restoreDeletedBranch").mockImplementation(restoreDeleted),
    spyOn(branchApi, "setBranchUpstream").mockImplementation(setTracking),
    spyOn(updates, "updateGitLogBranch").mockImplementation(update),
    spyOn(notifications, "showIdeaNotification").mockImplementation((card) => {
      notificationsShown.push(card);
      return "toast";
    }),
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
          data-action="checkout-remote"
          disabled={isMutating}
          onClick={() => onReferenceAction("checkout", remoteReference)}
        >
          Checkout Remote
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
        <button
          data-action="delete-local"
          onClick={() => onReferenceAction("deleteLocal", reference)}
        >
          Delete Local
        </button>
      </div>
    )),
    spyOn(table, "GitCommitTable").mockImplementation(() => <></>),
    spyOn(inspector, "GitCommitInspector").mockImplementation(() => <></>),
    spyOn(title, "GitLogTitleBar").mockImplementation(() => <></>),
    spyOn(toast, "success").mockImplementation(success),
    spyOn(toast, "error").mockImplementation(failure),
    spyOn(toast, "warning").mockImplementation(warning),
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
    useGitLogPreferencesStore.setState(previousGitLogPreferences, true);
    container.remove();
    if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
    else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
const render = async (language: "en-US" | "zh-CN" = "en-US") =>
  act(async () =>
    root.render(
      <LocaleProvider language={language}>
        <GitLogToolWindow />
      </LocaleProvider>,
    ),
  );
const button = (action: string) =>
  container.querySelector<HTMLButtonElement>(`[data-action="${action}"]`)!;
// Notification actions start an async restore without returning its promise, so advance the
// microtask queue explicitly instead of waiting on a real timer.
const flushPromises = async () => {
  for (let turn = 0; turn < 5; turn += 1) await Promise.resolve();
};

test("Git Log Checkout starts directly without a second confirmation and refreshes afterwards", async () => {
  await render();
  await act(async () => button("checkout").click());
  expect(confirm).not.toHaveBeenCalled();
  expect(checkout.mock.calls).toEqual([["C:/repo-a", reference]]);
  expect(refresh).toHaveBeenCalledTimes(1);
  // Like IDEA, a successful checkout needs no popup; the branch label switching is the feedback.
  expect(success).not.toHaveBeenCalled();
});

test.each([
  ["en-US", "checkout"],
  ["zh-CN", "checkout"],
  ["en-US", "checkout-remote"],
  ["zh-CN", "checkout-remote"],
] as const)("Checkout shows no success popup for %s / %s", async (language, action) => {
  await render(language);
  await act(async () => button(action).click());
  expect(success).not.toHaveBeenCalled();
  expect(failure).not.toHaveBeenCalled();
  expect(confirm).not.toHaveBeenCalled();
  expect(checkout.mock.calls).toEqual([["C:/repo-a", action === "checkout" ? reference : remoteReference]]);
  expect(refresh).toHaveBeenCalledTimes(1);
});

test.each([
  ["en-US", "Could not checkout topic"],
  ["zh-CN", "无法签出 topic"],
] as const)("Checkout failure uses the IDEA sticky error balloon in %s", async (language, title) => {
  checkout.mockImplementationOnce(async () => ({
    success: false,
    hasChanges: false,
    message: "fatal: 'topic' is already used by worktree at 'C:/wt/topic'",
  }));
  await render(language);
  await act(async () => button("checkout").click());
  expect(success).not.toHaveBeenCalled();
  expect(failure).toHaveBeenCalledTimes(1);
  const [message, options] = failure.mock.calls[0]!;
  expect(message).toBe(title);
  expect(options?.description).toBe("'topic' is already used by worktree at 'C:/wt/topic'");
  expect(options?.duration).toBe(Number.POSITIVE_INFINITY);
  expect(options?.icon).toBeTruthy();
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

test("Restore keeps the branch and warns when upstream tracking cannot be restored", async () => {
  setTracking.mockImplementationOnce(async () => {
    throw new Error("could not lock config file .git/config");
  });
  await render();
  await act(async () => button("delete-local").click());
  expect(deleteLocal.mock.calls).toEqual([["C:/repo-a", "topic"]]);
  const card = notificationsShown[0]!;
  expect(card.title).toBe("Deleted Branch:");
  expect(card.message).toBe("topic");

  refresh.mockClear();
  await act(async () => {
    card.actions![0]!.onClick();
    await flushPromises();
  });

  expect(restoreDeleted.mock.calls).toEqual([
    ["C:/repo-a", { name: "topic", deletedTarget: "abc123def456" }],
  ]);
  expect(setTracking.mock.calls).toEqual([["C:/repo-a", "topic", trackingRemote]]);
  // The branch itself is back, so the whole restore must not be reported as a failure that
  // would push the user to create a duplicate branch.
  expect(failure).not.toHaveBeenCalled();
  expect(success).not.toHaveBeenCalled();
  expect(warning).toHaveBeenCalledTimes(1);
  const [message, options] = warning.mock.calls[0]!;
  expect(message).toBe(
    "Restored branch topic, but could not restore its upstream tracking (origin/topic)",
  );
  expect(options?.description).toBe("could not lock config file .git/config");
  expect(refresh).toHaveBeenCalledTimes(1);
});
