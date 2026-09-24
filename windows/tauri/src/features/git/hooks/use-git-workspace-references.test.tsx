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

const getGitReferences = mock(
  async (repoPath: string): Promise<GitReferenceSnapshot> => {
    const key = repoPath.replace(/\\/g, "/").replace(/\/+$/, "");
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
  getGitReferences.mockClear();
  cancelGitHistoryOperation.mockClear();
  spies.push(
    spyOn(historyApi, "cancelGitHistoryOperation").mockImplementation(cancelGitHistoryOperation),
    spyOn(historyApi, "getGitReferences").mockImplementation(getGitReferences),
  );
});

const { emitGitChanged } = await import("../events/git-events");
const { useGitWorkspaceReferences } = await import("./use-git-workspace-references");

type WorkspaceReferences = ReturnType<typeof useGitWorkspaceReferences>;

function mountHook(scheduler?: GitWorkspaceReferencesScheduler): {
  read: () => WorkspaceReferences;
  render: (repositoryPaths: string[]) => Promise<void>;
  root: Root;
} {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  let current: WorkspaceReferences | null = null;

  function Probe({ repositoryPaths }: { repositoryPaths: string[] }): ReactNode {
    current = useGitWorkspaceReferences(repositoryPaths, scheduler);
    return null;
  }

  return {
    read: () => {
      if (!current) throw new Error("Git workspace references hook has not rendered");
      return current;
    },
    render: async (repositoryPaths) => {
      await act(async () => {
        root.render(<Probe repositoryPaths={repositoryPaths} />);
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

describe("Git workspace references", () => {
  test("tags every reference with its repository and groups them by normalized path", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:\\repo-a\\", "C:/repo-b"]);
      const { referencesByRepository } = harness.read();

      expect([...referencesByRepository.keys()]).toEqual(["C:/repo-a", "C:/repo-b"]);
      expect(referencesByRepository.get("C:/repo-a")).toEqual([
        { ...referenceFor("main"), repositoryPath: "C:/repo-a" },
      ]);
      expect(
        referencesByRepository.get("C:/repo-b")?.map((reference) => reference.repositoryPath),
      ).toEqual(["C:/repo-b", "C:/repo-b"]);
      expect(
        referencesByRepository.get("C:/repo-b")?.map((reference) => reference.shortName),
      ).toEqual(["develop", "feature/x"]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });

  test("keeps a single repository in one group", async () => {
    const harness = mountHook();
    try {
      await harness.render(["C:/repo-a"]);
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

  test("refreshes only the repository named by a Git change", async () => {
    const timer = new ManualTimer();
    const harness = mountHook(timer.scheduler);
    try {
      await harness.render(["C:/repo-a", "C:/repo-b"]);
      getGitReferences.mockClear();
      referencesByRepository["C:/repo-a"] = [referenceFor("main"), referenceFor("release")];

      await act(async () => {
        emitGitChanged({ repoPath: "C:/repo-a", scopes: ["refs"], source: "test" });
      });
      expect(timer.pending).toBe(1);

      await act(async () => {
        timer.fireNext();
      });

      expect(getGitReferences.mock.calls.map(([repoPath]) => repoPath)).toEqual(["C:/repo-a"]);
      expect(
        harness.read().referencesByRepository.get("C:/repo-a")?.map((reference) => reference.shortName),
      ).toEqual(["main", "release"]);
    } finally {
      await act(async () => {
        harness.root.unmount();
      });
    }
  });
});
