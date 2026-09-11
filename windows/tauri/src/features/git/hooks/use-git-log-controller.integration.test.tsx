import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as historyApi from "../api/git-commits-api";
import type {
  GitCommit,
  GitHistoryPage,
  GitReference,
  GitReferenceSnapshot,
} from "../types/git.types";

let restoreDom: () => void;
let originalCustomEvent: typeof globalThis.CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalActEnvironment: boolean | undefined;
const spies: Array<{ mockRestore: () => void }> = [];

const mainReference = (): GitReference => ({
  fullName: "refs/heads/main",
  shortName: "main",
  kind: "local",
  peelsToCommit: true,
  isCurrent: true,
  upstreamShortName: "origin/main",
  ahead: 0,
  behind: 0,
});

const commitFor = (repoPath: string): GitCommit => ({
  hash: repoPath === "C:/repo-a" ? "a".repeat(40) : "b".repeat(40),
  shortHash: repoPath === "C:/repo-a" ? "aaaaaaa" : "bbbbbbb",
  parentHashes: [],
  message: repoPath,
  author: "Lithe Test",
  date: "2026/09/08 10:00",
  decorations: "HEAD -> main",
});

const getGitReferences = mock(
  async (): Promise<GitReferenceSnapshot> => ({
    references: [mainReference()],
    recentReferences: [mainReference()],
  }),
);
const getGitHistoryPage = mock(
  async (repoPath: string): Promise<GitHistoryPage> => ({
    commits: [commitFor(repoPath)],
    hasMore: false,
  }),
);
const cancelGitHistoryOperation = mock(async () => {});
const closeGitHistoryCursor = mock(async () => {});

beforeEach(() => {
  restoreDom = installHappyDom();
  originalCustomEvent = globalThis.CustomEvent;
  originalActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  Object.defineProperty(globalThis, "CustomEvent", {
    configurable: true,
    writable: true,
    value: window.CustomEvent,
  });
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  spies.push(
    spyOn(historyApi, "cancelGitHistoryOperation").mockImplementation(cancelGitHistoryOperation),
    spyOn(historyApi, "closeGitHistoryCursor").mockImplementation(closeGitHistoryCursor),
    spyOn(historyApi, "getGitHistoryPage").mockImplementation(getGitHistoryPage),
    spyOn(historyApi, "getGitReferences").mockImplementation(getGitReferences),
  );
});

const { emitGitChanged } = await import("../events/git-events");
const { useGitLogController } = await import("./use-git-log-controller");

type GitLogController = ReturnType<typeof useGitLogController>;
type ControllerRender = {
  repoPath: string;
  commitMessages: string[];
};

function mountController(): {
  read: () => GitLogController;
  renders: () => readonly ControllerRender[];
  render: (repoPath: string) => Promise<void>;
  root: Root;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  let current: GitLogController | null = null;
  const renders: ControllerRender[] = [];

  function Probe({ repoPath }: { repoPath: string }): ReactNode {
    current = useGitLogController(repoPath);
    renders.push({
      repoPath,
      commitMessages: current.history.commits.map((commit) => commit.message),
    });
    return null;
  }

  return {
    read: () => {
      if (!current) throw new Error("Git Log controller has not rendered");
      return current;
    },
    renders: () => renders,
    render: async (repoPath) => {
      await act(async () => {
        root.render(
          <LocaleProvider language="en-US">
            <Probe repoPath={repoPath} />
          </LocaleProvider>,
        );
      });
    },
    root,
  };
}

afterEach(() => {
  for (const spy of spies.splice(0)) spy.mockRestore();
  if (originalActEnvironment === undefined) {
    delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
  } else {
    actGlobal.IS_REACT_ACT_ENVIRONMENT = originalActEnvironment;
  }
  document.body.replaceChildren();
  if (originalCustomEvent) {
    Object.defineProperty(globalThis, "CustomEvent", {
      configurable: true,
      writable: true,
      value: originalCustomEvent,
    });
  } else {
    Reflect.deleteProperty(globalThis, "CustomEvent");
  }
  restoreDom();
});

describe("Git Log controller repository lifecycle", () => {
  test("rejects a refresh callback captured by the previous repository", async () => {
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      const refreshRepoA = harness.read().refresh;
      const renderCountBeforeSwitch = harness.renders().length;

      await harness.render("C:/repo-b");
      const repoBRenders = harness.renders().slice(renderCountBeforeSwitch);
      expect(repoBRenders).not.toContainEqual({
        repoPath: "C:/repo-b",
        commitMessages: ["C:/repo-a"],
      });
      expect(harness.read().history.commits[0]?.message).toBe("C:/repo-b");
      const pageCallsBeforeStaleRefresh = getGitHistoryPage.mock.calls.length;

      await act(async () => {
        await refreshRepoA();
      });

      expect(getGitHistoryPage).toHaveBeenCalledTimes(pageCallsBeforeStaleRefresh);
      expect(harness.read().history.commits[0]?.message).toBe("C:/repo-b");
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("cancels an event refresh when the owner immediately refreshes directly", async () => {
    const harness = mountController();

    const originalSetTimeout = globalThis.setTimeout;
    const originalClearTimeout = globalThis.clearTimeout;
    const timerHandle = 4242 as unknown as ReturnType<typeof setTimeout>;
    let pendingCallback: (() => void) | null = null;
    let wasCancelled = false;
    globalThis.setTimeout = ((callback: TimerHandler) => {
      if (typeof callback !== "function") throw new Error("Expected a timer callback");
      pendingCallback = () => Reflect.apply(callback, undefined, []);
      return timerHandle;
    }) as unknown as typeof setTimeout;
    globalThis.clearTimeout = ((handle: ReturnType<typeof setTimeout>) => {
      if (handle === timerHandle) {
        wasCancelled = true;
        pendingCallback = null;
      }
    }) as typeof clearTimeout;

    try {
      await harness.render("C:/repo-a");
      getGitHistoryPage.mockClear();
      act(() => {
        emitGitChanged({
          repoPath: "C:/repo-a",
          scopes: ["history", "refs"],
          source: "pull-finished",
        });
      });
      await act(async () => {
        await harness.read().refresh();
      });
      if (pendingCallback) {
        await act(async () => {
          pendingCallback?.();
        });
      }

      expect(wasCancelled).toBe(true);
      expect(getGitHistoryPage).toHaveBeenCalledTimes(1);
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
      await act(async () => {
        harness.root.unmount();
      });
    }
  });
});
