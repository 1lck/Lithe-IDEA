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
const defaultHistoryPage = async (
  repoPath: string,
  _cursor?: string,
  _limit?: number,
  _operationId?: string,
  _reference?: string,
): Promise<GitHistoryPage> => ({
  commits: [commitFor(repoPath)],
  hasMore: false,
});
const getGitHistoryPage = mock(defaultHistoryPage);
const cancelGitHistoryOperation = mock(async (_operationId: string) => {});
const closeGitHistoryCursor = mock(async (_repoPath: string, _cursor: string) => {});
const visiblePageCalls = () => getGitHistoryPage.mock.calls.filter((call) => call[2] !== 5_000);

beforeEach(() => {
  getGitHistoryPage.mockReset();
  getGitHistoryPage.mockImplementation(defaultHistoryPage);
  getGitReferences.mockReset();
  getGitReferences.mockImplementation(async () => ({
    references: [mainReference()],
    recentReferences: [mainReference()],
  }));
  cancelGitHistoryOperation.mockClear();
  closeGitHistoryCursor.mockClear();
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

function graphGate() {
  let release!: (page: GitHistoryPage) => void;
  const promise = new Promise<GitHistoryPage>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}

function mountController(): {
  read: () => GitLogController;
  renders: () => readonly ControllerRender[];
  render: (repoPath: string, preferredReference?: GitReference | null) => Promise<void>;
  root: Root;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  let current: GitLogController | null = null;
  const renders: ControllerRender[] = [];

  function Probe({
    repoPath,
    preferredReference,
  }: {
    repoPath: string;
    preferredReference: GitReference | null;
  }): ReactNode {
    current = useGitLogController(repoPath, preferredReference);
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
    render: async (repoPath, preferredReference = null) => {
      await act(async () => {
        root.render(
          <LocaleProvider language="en-US">
            <Probe repoPath={repoPath} preferredReference={preferredReference} />
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
  test("shows the visible page before bounded repository context finishes and closes its independent cursor", async () => {
    const gate = graphGate();
    getGitHistoryPage.mockImplementation((...args) =>
      args[2] === 5_000 ? gate.promise : defaultHistoryPage(...args),
    );
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      expect(harness.read().loadState).toBe("ready");
      expect(harness.read().history.commits).toEqual([commitFor("C:/repo-a")]);
      expect(harness.read().repositoryCommits).toEqual([]);
      const graphCalls = getGitHistoryPage.mock.calls.filter((call) => call[2] === 5_000);
      expect(graphCalls).toHaveLength(1);
      expect(graphCalls[0][4]).toBeUndefined();
      await act(async () =>
        gate.release({
          commits: [commitFor("C:/repo-a")],
          hasMore: true,
          nextCursor: "graph-cursor",
        }),
      );
      expect(harness.read().repositoryCommits).toEqual([commitFor("C:/repo-a")]);
      expect(closeGitHistoryCursor).toHaveBeenCalledWith("C:/repo-a", "graph-cursor");
    } finally {
      await act(async () => {
        gate.release({ commits: [], hasMore: false });
        harness.root.unmount();
      });
    }
  });

  test("repository switches cancel graph reads and close late cursors without publishing old context", async () => {
    const gate = graphGate();
    getGitHistoryPage.mockImplementation((...args) =>
      args[0] === "C:/repo-a" && args[2] === 5_000 ? gate.promise : defaultHistoryPage(...args),
    );
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      const graphOperation = getGitHistoryPage.mock.calls.find((call) => call[2] === 5_000)![3]!;
      await harness.render("C:/repo-b");
      expect(cancelGitHistoryOperation).toHaveBeenCalledWith(graphOperation);
      await act(async () =>
        gate.release({
          commits: [commitFor("C:/repo-a")],
          hasMore: true,
          nextCursor: "late-repo-a",
        }),
      );
      expect(harness.read().repositoryCommits).toEqual([commitFor("C:/repo-b")]);
      expect(closeGitHistoryCursor).toHaveBeenCalledWith("C:/repo-a", "late-repo-a");
    } finally {
      await act(async () => {
        gate.release({ commits: [], hasMore: false });
        harness.root.unmount();
      });
    }
  });

  test("pagination keeps the in-flight graph read and visible cursor independent", async () => {
    const gate = graphGate();
    getGitHistoryPage.mockImplementation((...args) =>
      args[2] === 5_000
        ? gate.promise
        : Promise.resolve({
            commits: [{ ...commitFor(args[0]), hash: args[1] ? "older" : "tip" }],
            hasMore: !args[1],
            nextCursor: args[1] ? undefined : "visible-cursor",
          }),
    );
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      await act(async () => {
        await harness.read().loadMore();
      });
      expect(harness.read().history.commits.map((commit) => commit.hash)).toEqual(["tip", "older"]);
      expect(getGitHistoryPage.mock.calls.filter((call) => call[2] === 5_000)).toHaveLength(1);
      expect(cancelGitHistoryOperation.mock.calls.some(([id]) => id.includes("-graph-"))).toBe(
        false,
      );
      expect(visiblePageCalls()[1][1]).toBe("visible-cursor");
      await act(async () => gate.release({ commits: [commitFor("C:/repo-a")], hasMore: false }));
      expect(harness.read().repositoryCommits).toEqual([commitFor("C:/repo-a")]);
    } finally {
      await act(async () => {
        gate.release({ commits: [], hasMore: false });
        harness.root.unmount();
      });
    }
  });

  test("a newer refresh owns graph context even when the previous refresh returns last", async () => {
    const gate = graphGate();
    let graphReads = 0;
    const newest = { ...commitFor("C:/repo-a"), hash: "newest" };
    getGitHistoryPage.mockImplementation((...args) => {
      if (args[2] !== 5_000) return defaultHistoryPage(...args);
      graphReads += 1;
      return graphReads === 1
        ? gate.promise
        : Promise.resolve({ commits: [newest], hasMore: false });
    });
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      const graphOperation = getGitHistoryPage.mock.calls.find((call) => call[2] === 5_000)![3]!;
      await act(async () => {
        await harness.read().refresh();
      });
      expect(cancelGitHistoryOperation).toHaveBeenCalledWith(graphOperation);
      await act(async () =>
        gate.release({
          commits: [commitFor("C:/repo-a")],
          nextCursor: "old-refresh",
          hasMore: true,
        }),
      );
      expect(harness.read().repositoryCommits).toEqual([newest]);
      expect(closeGitHistoryCursor).toHaveBeenCalledWith("C:/repo-a", "old-refresh");
    } finally {
      await act(async () => {
        gate.release({ commits: [], hasMore: false });
        harness.root.unmount();
      });
    }
  });

  test("unmount cancels context ownership and releases a late graph cursor", async () => {
    const gate = graphGate();
    getGitHistoryPage.mockImplementation((...args) =>
      args[2] === 5_000 ? gate.promise : defaultHistoryPage(...args),
    );
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      const operation = getGitHistoryPage.mock.calls.find((call) => call[2] === 5_000)![3]!;
      await act(async () => harness.root.unmount());
      expect(cancelGitHistoryOperation).toHaveBeenCalledWith(operation);
      await act(async () =>
        gate.release({ commits: [commitFor("C:/repo-a")], hasMore: true, nextCursor: "unmounted" }),
      );
      expect(closeGitHistoryCursor).toHaveBeenCalledWith("C:/repo-a", "unmounted");
    } finally {
      await act(async () => {
        gate.release({ commits: [], hasMore: false });
        harness.root.unmount();
      });
    }
  });

  test("unexpected graph failures retain the usable visible history and report diagnostics", async () => {
    const error = new Error("graph request failed");
    const log = spyOn(console, "error").mockImplementation(() => {});
    getGitHistoryPage.mockImplementation((...args) =>
      args[2] === 5_000 ? Promise.reject(error) : defaultHistoryPage(...args),
    );
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      expect(harness.read().loadState).toBe("ready");
      expect(harness.read().history.commits).toEqual([commitFor("C:/repo-a")]);
      expect(harness.read().repositoryCommits).toEqual([]);
      expect(log).toHaveBeenCalledWith("Failed to load Git graph context:", error);
    } finally {
      await act(async () => harness.root.unmount());
      log.mockRestore();
    }
  });

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

  test("loads a pending cross-repository reference with a single visible history request", async () => {
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      getGitHistoryPage.mockClear();

      const preferredReference: GitReference = {
        fullName: "refs/heads/feature",
        shortName: "feature",
        kind: "local",
        peelsToCommit: true,
        isCurrent: false,
        ahead: 0,
        behind: 0,
      };
      getGitReferences.mockImplementationOnce(async () => ({
        references: [preferredReference],
        recentReferences: [preferredReference],
      }));

      await harness.render("C:/repo-b", preferredReference);

      expect(visiblePageCalls()).toHaveLength(1);
      expect(visiblePageCalls()[0]?.[4]).toBe("refs/heads/feature");
      expect(harness.read().selectedReference?.fullName).toBe("refs/heads/feature");
      expect(harness.read().history.commits[0]?.message).toBe("C:/repo-b");
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("selects a remote symbolic HEAD with exactly one visible history request", async () => {
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      getGitHistoryPage.mockClear();

      const originHead: GitReference = {
        fullName: "refs/remotes/origin/HEAD",
        shortName: "origin/HEAD",
        kind: "remote",
        peelsToCommit: true,
        isCurrent: false,
      };
      const originMain: GitReference = {
        fullName: "refs/remotes/origin/main",
        shortName: "origin/main",
        kind: "remote",
        peelsToCommit: true,
        isCurrent: false,
      };
      // The snapshot lists the remote's branches but not the symbolic `origin/HEAD`.
      getGitReferences.mockImplementationOnce(async () => ({
        references: [originMain],
        recentReferences: [originMain],
      }));

      await act(async () => {
        harness.read().selectReference(originHead);
      });

      expect(visiblePageCalls()).toHaveLength(1);
      expect(visiblePageCalls()[0]?.[4]).toBe("refs/remotes/origin/HEAD");
      expect(harness.read().selectedReference?.fullName).toBe("refs/remotes/origin/HEAD");
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("falls back to an unfiltered load for a genuinely missing reference", async () => {
    const harness = mountController();
    try {
      await harness.render("C:/repo-a");
      getGitHistoryPage.mockClear();

      const deletedReference: GitReference = {
        fullName: "refs/remotes/origin/deleted",
        shortName: "origin/deleted",
        kind: "remote",
        peelsToCommit: true,
        isCurrent: false,
      };
      getGitReferences.mockImplementationOnce(async () => ({
        references: [],
        recentReferences: [],
      }));

      await act(async () => {
        harness.read().selectReference(deletedReference);
      });

      expect(visiblePageCalls()).toHaveLength(2);
      expect(harness.read().selectedReference).toBeNull();
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
      expect(visiblePageCalls()).toHaveLength(1);
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
      await act(async () => {
        harness.root.unmount();
      });
    }
  });
});
