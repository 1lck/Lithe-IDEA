import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as historyApi from "../api/git-commits-api";
import type { GitReference, GitReferenceSnapshot } from "../types/git.types";
import type { GitWorkspaceReferencesScheduler } from "./use-git-workspace-references";

let restoreDom: () => void;
let originalCustomEvent: typeof globalThis.CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalActEnvironment: boolean | undefined;
const spies: Array<{ mockRestore: () => void }> = [];

class ManualTimer {
  private nextId = 1;
  private readonly callbacks = new Map<number, () => void>();

  readonly scheduler: GitWorkspaceReferencesScheduler = {
    setTimer: (callback) => {
      const id = this.nextId++;
      this.callbacks.set(id, callback);
      return id as unknown as ReturnType<typeof setTimeout>;
    },
    clearTimer: (timer) => {
      this.callbacks.delete(timer as unknown as number);
    },
  };

  get pending(): number {
    return this.callbacks.size;
  }

  fireNext(): void {
    const id = [...this.callbacks.keys()].sort((left, right) => left - right)[0];
    if (id === undefined) throw new Error("No timer is scheduled.");
    const callback = this.callbacks.get(id);
    this.callbacks.delete(id);
    callback?.();
  }
}

const referenceFor = (shortName: string): GitReference => ({
  fullName: `refs/heads/${shortName}`,
  shortName,
  kind: "local",
  peelsToCommit: true,
  isCurrent: false,
});

let referencesByRepository: Record<string, GitReference[]> = {
  "C:/repo-a": [referenceFor("main")],
  "C:/repo-b": [referenceFor("develop"), referenceFor("feature/x")],
};

const failedRepositories = new Set<string>();

const getGitReferencesAtRoot = mock(
  async (repoPath: string): Promise<GitReferenceSnapshot> => {
    const key = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
    if (failedRepositories.has(key)) throw new Error(`failed to load ${key}`);
    return {
      references: referencesByRepository[key] ?? [],
      recentReferences: [],
    };
  },
);
const cancelGitHistoryOperation = mock(async () => {});

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
  referencesByRepository = {
    "C:/repo-a": [referenceFor("main")],
    "C:/repo-b": [referenceFor("develop"), referenceFor("feature/x")],
  };
  failedRepositories.clear();
  getGitReferencesAtRoot.mockClear();
  cancelGitHistoryOperation.mockClear();
  spies.push(
    spyOn(historyApi, "cancelGitHistoryOperation").mockImplementation(cancelGitHistoryOperation),
    spyOn(historyApi, "getGitReferencesAtRoot").mockImplementation(getGitReferencesAtRoot),
  );
});

const { emitGitChanged } = await import("../events/git-events");
const { useGitWorkspaceReferences } = await import("./use-git-workspace-references");

type WorkspaceReferences = ReturnType<typeof useGitWorkspaceReferences>;

function mountHook(scheduler?: GitWorkspaceReferencesScheduler): {
  read: () => WorkspaceReferences;
  render: (repositoryPaths: string[], activeRepositoryPath: string) => Promise<void>;
  root: Root;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  let current: WorkspaceReferences | null = null;

  function Probe({
    repositoryPaths,
    activeRepositoryPath,
  }: {
    repositoryPaths: string[];
    activeRepositoryPath: string;
  }): ReactNode {
    current = useGitWorkspaceReferences(repositoryPaths, activeRepositoryPath, scheduler);
    return null;
  }

  return {
    read: () => {
      if (!current) throw new Error("Git workspace references hook has not rendered");
      return current;
    },
    render: async (repositoryPaths, activeRepositoryPath) => {
      await act(async () => {
        root.render(
          <Probe repositoryPaths={repositoryPaths} activeRepositoryPath={activeRepositoryPath} />,
        );
      });
    },
    root,
  };
}

const readRepositoryPaths = () =>
  getGitReferencesAtRoot.mock.calls.map(([repoPath]) => repoPath);

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

describe("Git workspace references", () => {
  test("loads the active repository and tags its references with the normalized path", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:\\repo-a\\", "C:/repo-b"], "C:/repo-a");

      expect(readRepositoryPaths()).toEqual(["C:/repo-a"]);
      expect([...harness.read().referencesByRepository.keys()]).toEqual(["C:/repo-a"]);
      expect(harness.read().referencesByRepository.get("C:/repo-a")).toEqual([
        { ...referenceFor("main"), repositoryPath: "C:/repo-a" },
      ]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("loads a non-active repository only when it is requested", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"], "C:/repo-a");
      expect(harness.read().referencesByRepository.has("C:/repo-b")).toBe(false);

      await act(async () => {
        await harness.read().ensureRepository("C:/repo-b");
      });

      expect(readRepositoryPaths()).toEqual(["C:/repo-a", "C:/repo-b"]);
      expect(
        harness.read().referencesByRepository.get("C:/repo-b")?.map((reference) => reference.repositoryPath),
      ).toEqual(["C:/repo-b", "C:/repo-b"]);
      expect(
        harness.read().referencesByRepository.get("C:/repo-b")?.map((reference) => reference.shortName),
      ).toEqual(["develop", "feature/x"]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("caches a requested repository until the hook re-requests it", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"], "C:/repo-a");
      await act(async () => {
        await harness.read().ensureRepository("C:/repo-b");
      });
      getGitReferencesAtRoot.mockClear();

      await act(async () => {
        await harness.read().ensureRepository("C:/repo-b");
      });

      expect(readRepositoryPaths()).toEqual([]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("keeps a single repository in one group", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:/repo-a"], "C:/repo-a");
      const { referencesByRepository } = harness.read();

      expect(referencesByRepository.size).toBe(1);
      expect(referencesByRepository.get("C:/repo-a")?.map((reference) => reference.shortName)).toEqual(
        ["main"],
      );
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("refreshes only the requested repository named by a Git change", async () => {
    const timer = new ManualTimer();
    const harness = mountHook(timer.scheduler);
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"], "C:/repo-a");
      getGitReferencesAtRoot.mockClear();
      referencesByRepository["C:/repo-a"] = [referenceFor("main"), referenceFor("release")];

      await act(async () => {
        emitGitChanged({ repoPath: "C:/repo-a", scopes: ["refs"], source: "test" });
      });
      expect(timer.pending).toBe(1);

      await act(async () => {
        timer.fireNext();
      });

      expect(readRepositoryPaths()).toEqual(["C:/repo-a"]);
      expect(
        harness.read().referencesByRepository.get("C:/repo-a")?.map((reference) => reference.shortName),
      ).toEqual(["main", "release"]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("ignores a Git change for a repository that was never requested", async () => {
    const timer = new ManualTimer();
    const harness = mountHook(timer.scheduler);
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"], "C:/repo-a");
      getGitReferencesAtRoot.mockClear();

      await act(async () => {
        emitGitChanged({ repoPath: "C:/repo-b", scopes: ["refs"], source: "test" });
      });

      expect(timer.pending).toBe(0);
      expect(readRepositoryPaths()).toEqual([]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("records a per-repository error and retries without showing a false empty group", async () => {
    failedRepositories.add("C:/repo-b");
    const harness = mountHook();
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"], "C:/repo-a");
      await act(async () => {
        await harness.read().ensureRepository("C:/repo-b");
      });

      expect(harness.read().errorsByRepository.get("C:/repo-b")).toBe(
        "failed to load C:/repo-b",
      );
      expect(harness.read().referencesByRepository.has("C:/repo-b")).toBe(false);

      failedRepositories.delete("C:/repo-b");
      await act(async () => {
        await harness.read().retryRepository("C:/repo-b");
      });

      expect(harness.read().errorsByRepository.has("C:/repo-b")).toBe(false);
      expect(
        harness.read().referencesByRepository.get("C:/repo-b")?.map((reference) => reference.shortName),
      ).toEqual(["develop", "feature/x"]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });
});
