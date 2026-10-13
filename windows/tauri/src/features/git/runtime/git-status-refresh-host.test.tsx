import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as tauriEvents from "@tauri-apps/api/event";
import * as tauriCore from "@/platform/tauri-core";
import * as projectStore from "@/features/window/stores/project.store";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as fileSystem from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as statusApi from "../api/git-status-api";
import { emitGitChanged } from "../events/git-events";
import { useGitStore } from "../stores/git.store";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitStatus } from "../types/git.types";
import { GitStatusRefreshHost, type GitStatusRefreshScheduler } from "./git-status-refresh-host";
import { GitMetadataWatchHost } from "./git-metadata-watch-host";

class ManualTimer {
  private nextId = 0;
  readonly callbacks = new Map<number, () => void>();
  readonly scheduler: GitStatusRefreshScheduler = {
    setTimer: (callback) => {
      const id = ++this.nextId;
      this.callbacks.set(id, callback);
      return id as unknown as ReturnType<typeof setTimeout>;
    },
    clearTimer: (timer) => {
      this.callbacks.delete(timer as unknown as number);
    },
  };
  fire() {
    const callbacks = [...this.callbacks.values()];
    this.callbacks.clear();
    for (const callback of callbacks) callback();
  }
}

const repo = "C:/fixture";
const folders = [{ path: repo, name: "Fixture", isPrimary: true }];
const snapshot = (branch: string, behind: number): GitStatus => ({
  branch,
  ahead: 0,
  behind,
  files: [],
});
let nextStatus: GitStatus;
let restoreDom: () => void;
let previousCustomEvent: typeof CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let previousGit: ReturnType<typeof useGitStore.getState>;
let previousRepositories: ReturnType<typeof useRepositoryStore.getState>;
let container: HTMLDivElement;
let root: Root | undefined;
let timer: ManualTimer;
const spies: Array<{ mockRestore: () => void }> = [];
const readStatuses = mock(async () => ({ [repo]: nextStatus }));

beforeEach(() => {
  restoreDom = installHappyDom();
  previousCustomEvent = globalThis.CustomEvent;
  globalThis.CustomEvent = window.CustomEvent;
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousGit = useGitStore.getState();
  previousRepositories = useRepositoryStore.getState();
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "ready");
  useRepositoryStore.getState().actions.reset();
  useRepositoryStore.getState().actions.setManualRepository(repo);
  useGitStore.getState().actions.reset();
  useGitStore.getState().actions.setWorkspaceRepository(repo);
  useGitStore.getState().actions.prepareRepositoryLoad(repo);
  nextStatus = snapshot("old", 3);
  timer = new ManualTimer();
  readStatuses.mockClear();
  spies.push(
    spyOn(statusApi, "getRepositoryGitStatuses").mockImplementation(readStatuses),
    spyOn(useRepositoryStore.getState().actions, "syncWorkspaceRepositories").mockResolvedValue(),
    spyOn(fileSystem, "useFileSystemStore").mockImplementation(((
      selector: (state: { rootFolderPath: string; workspaceFolders: typeof folders }) => unknown,
    ) =>
      selector({
        rootFolderPath: repo,
        workspaceFolders: folders,
      })) as typeof fileSystem.useFileSystemStore),
  );
});

afterEach(async () => {
  try {
    await act(async () => {
      root?.unmount();
    });
  } finally {
    root = undefined;
    container?.remove();
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    useGitStore.setState(previousGit, true);
    useRepositoryStore.setState(previousRepositories, true);
    workspaceRuntimeRegistry.resetForTests();
    globalThis.CustomEvent = previousCustomEvent;
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
});

async function mount(element = <GitStatusRefreshHost scheduler={timer.scheduler} />) {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  // Only the workspace host is mounted: no Commit panel/controller supplies refreshes.
  await act(async () => {
    root!.render(element);
  });
}

test("external pull and checkout refresh the shared snapshot with Commit closed", async () => {
  await mount();
  expect(useGitStore.getState().repositoryStatuses[repo]?.behind).toBe(3);
  nextStatus = snapshot("latest", 0);
  emitGitChanged({
    repoPath: repo,
    source: "external-git-change",
    scopes: ["refs", "working-tree"],
  });
  emitGitChanged({ repoPath: repo, source: "external-git-change", scopes: ["repository"] });
  expect(timer.callbacks.size).toBe(1);
  await act(async () => {
    timer.fire();
  });
  expect(readStatuses).toHaveBeenCalledTimes(2);
  const state = useGitStore.getState();
  expect(state.repositoryStatuses[repo]?.branch).toBe("latest");
  expect(state.repositoryStatuses[repo]?.behind).toBe(0);
  expect(state.gitStatus).toBe(state.repositoryStatuses[repo]);
  expect(state.workspaceGitStatus).toBe(state.repositoryStatuses[repo]);
}, 1000);

test("unrelated repository changes do not query status and unmount cancels pending work", async () => {
  await mount();
  emitGitChanged({ repoPath: "C:/unrelated", source: "external-git-change" });
  expect(timer.callbacks.size).toBe(0);
  emitGitChanged({ repoPath: repo, source: "external-git-change" });
  expect(timer.callbacks.size).toBe(1);
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  expect(timer.callbacks.size).toBe(0);
  emitGitChanged({ repoPath: repo, source: "external-git-change" });
  timer.fire();
  expect(readStatuses).toHaveBeenCalledTimes(1);
}, 1000);

test("metadata watches cover every repository, replace links and release all identifiers", async () => {
  const child = `${repo}/child`;
  useRepositoryStore.setState({ availableRepoPaths: [repo, child] });
  const nativeInvoke = mock(async (_command: string, _args?: Record<string, unknown>) => undefined);
  const unlisten = mock(() => {});
  let onMetadataChange!: (event: {
    payload: { repositoryRoots: string[]; metadataLinkChanged: boolean };
  }) => void;
  spies.push(
    spyOn(tauriCore, "invoke").mockImplementation(nativeInvoke as typeof tauriCore.invoke),
    spyOn(tauriEvents, "listen").mockImplementation((async (_event, listener) => {
      onMetadataChange = listener as typeof onMetadataChange;
      return unlisten;
    }) as typeof tauriEvents.listen),
    spyOn(projectStore, "useProjectStore").mockImplementation(((
      selector: (state: { rootFolderPath: string }) => unknown,
    ) => selector({ rootFolderPath: repo })) as typeof projectStore.useProjectStore),
  );
  await mount(<GitMetadataWatchHost />);
  const initialWatches = nativeInvoke.mock.calls.filter(
    ([command]) => command === "watch_git_repository",
  );
  expect(initialWatches.map(([, args]) => args?.repoPath)).toEqual([repo, child]);
  const ids = initialWatches.map(([, args]) => args!.watchId);
  await act(async () => {
    onMetadataChange({ payload: { repositoryRoots: [child], metadataLinkChanged: true } });
  });
  const replacementWatches = nativeInvoke.mock.calls.filter(
    ([command]) => command === "watch_git_repository",
  );
  expect(replacementWatches).toHaveLength(4);
  expect(new Set(replacementWatches.map(([, args]) => args!.watchId)).size).toBe(2);
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  const releasedIds = nativeInvoke.mock.calls
    .filter(([command]) => command === "unwatch_git_repository")
    .map(([, args]) => args!.watchId);
  for (const id of ids) expect(releasedIds.filter((released) => released === id)).toHaveLength(2);
  expect(unlisten).toHaveBeenCalledTimes(1);
}, 1000);

test("a native watch that finishes after unmount is released again", async () => {
  let releaseWatch!: () => void;
  const watchGate = new Promise<void>((resolve) => { releaseWatch = resolve; });
  const nativeInvoke = mock(async (command: string, _args?: Record<string, unknown>) => {
    if (command === "watch_git_repository") await watchGate;
  });
  spies.push(
    spyOn(tauriCore, "invoke").mockImplementation(nativeInvoke as typeof tauriCore.invoke),
    spyOn(tauriEvents, "listen").mockResolvedValue(() => {}),
    spyOn(projectStore, "useProjectStore").mockImplementation(
      ((selector: (state: { rootFolderPath: string }) => unknown) => selector({ rootFolderPath: repo })) as typeof projectStore.useProjectStore,
    ),
  );
  try {
    await mount(<GitMetadataWatchHost />);
    expect(nativeInvoke.mock.calls.filter(([command]) => command === "watch_git_repository")).toHaveLength(1);
    await act(async () => { root!.unmount(); });
    root = undefined;
    expect(nativeInvoke.mock.calls.filter(([command]) => command === "unwatch_git_repository")).toHaveLength(1);
    await act(async () => { releaseWatch(); await watchGate; });
    expect(nativeInvoke.mock.calls.filter(([command]) => command === "unwatch_git_repository")).toHaveLength(2);
  } finally {
    releaseWatch();
    await watchGate;
  }
}, 1000);
