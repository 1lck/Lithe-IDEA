import * as lspAdapter from "@/platform/lsp-core-adapter";
import { useLspStore } from "@/features/editor/lsp/stores/lsp.store";
import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useSpringStore } from "../stores/spring.store";
import { EMPTY_SPRING_INDEX, type SpringIndex } from "../types/spring.types";
import {
  subscribeSpringDependencyReady,
  useSpringIndex,
  type SpringIndexDependencies,
} from "./use-spring-index";

const WORKSPACE_A = "spring-index-hook-a";
const WORKSPACE_B = "spring-index-hook-b";
const ROOT_A = "C:/fixture/a";
const ROOT_B = "D:/fixture/b";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function files(root: string) {
  return [{ name: "Controller.java", path: `${root}/src/Controller.java`, isDir: false }];
}

function index(root: string): SpringIndex {
  return {
    ...EMPTY_SPRING_INDEX,
    endpoints: [
      {
        id: root,
        httpMethods: ["GET"],
        route: "/fixture",
        controller: "Controller",
        method: "get",
        path: "src/Controller.java",
        line: 1,
        column: 1,
      },
    ],
  };
}

let scheduled: Array<{ reload: () => void; cancelled: boolean }>;
let dependencies: SpringIndexDependencies;
let requestIndex: ReturnType<typeof mock<SpringIndexDependencies["requestIndex"]>>;
let container: HTMLDivElement;
let root: Root;
let restoreDom: () => void;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousLsp: ReturnType<typeof useLspStore.getState>;
let restoreSessionLookup: (() => void) | undefined;

function Probe() {
  useSpringIndex(dependencies);
  return null;
}

function prepareWorkspace(id: string, path: string) {
  workspaceRuntimeRegistry.ensureWorkspace({ id, name: id }, "ready");
  const store = useFileSystemStore.getStore(id);
  store.setState({ rootFolderPath: path, getAllProjectFiles: async () => files(path) });
  return store;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  previousLsp = useLspStore.getState();
  useLspStore.setState({ lspStatus: { ...previousLsp.lspStatus, lifecycleBySession: {} } });
  scheduled = [];
  requestIndex = mock(async (args) => index(args.root));
  dependencies = {
    requestIndex,
    resolveMetadataRepository: async () => undefined,
    scheduleReload: (reload) => {
      const entry = { reload, cancelled: false };
      scheduled.push(entry);
      return () => {
        entry.cancelled = true;
      };
    },
  };
  prepareWorkspace(WORKSPACE_A, ROOT_A);
  prepareWorkspace(WORKSPACE_B, ROOT_B);
  workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_A, name: "A" }, "ready");
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
  } finally {
    restoreSessionLookup?.();
    restoreSessionLookup = undefined;
    useLspStore.setState(previousLsp);
    container.remove();
    workspaceRuntimeRegistry.resetForTests();
    if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});

async function mount() {
  await act(async () => {
    root.render(<Probe />);
  });
}

async function activateB() {
  await act(async () => {
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_B, name: "B" }, "ready");
  });
}

function externalChange(path: string, event_type: string) {
  window.dispatchEvent(
    new window.CustomEvent("file-external-change", { detail: { path, event_type } }),
  );
}

test("a pending file scan is abandoned before starting native indexing after switching projects", async () => {
  const scan = deferred<ReturnType<typeof files>>();
  useFileSystemStore.getStore(WORKSPACE_A).setState({ getAllProjectFiles: () => scan.promise });
  try {
    await mount();
    expect(useSpringStore.getStore(WORKSPACE_A).getState().phase).toBe("loading");
    await activateB();
    await act(async () => {
      scan.resolve(files(ROOT_A));
    });
    expect(requestIndex.mock.calls.map(([args]) => args.root)).toEqual([ROOT_B]);
    expect(useSpringStore.getStore(WORKSPACE_B).getState().index).toEqual(index(ROOT_B));
  } finally {
    await act(async () => {
      scan.resolve(files(ROOT_A));
    });
  }
});

test("a late native result cannot replace another project's endpoints or recreate a closed workspace", async () => {
  const result = deferred<SpringIndex>();
  requestIndex.mockImplementationOnce(() => result.promise);
  try {
    await mount();
    expect(requestIndex).toHaveBeenCalledTimes(1);
    await activateB();
    workspaceRuntimeRegistry.removeWorkspace(WORKSPACE_A);
    await act(async () => {
      result.resolve(index(ROOT_A));
    });
    expect(workspaceRuntimeRegistry.hasWorkspace(WORKSPACE_A)).toBe(false);
    expect(useSpringStore.getStore(WORKSPACE_B).getState().index).toEqual(index(ROOT_B));
  } finally {
    await act(async () => {
      result.resolve(index(ROOT_A));
    });
  }
});

test("workspace identity changes restart indexing even when the root string is unchanged", async () => {
  prepareWorkspace(WORKSPACE_B, ROOT_A);
  await mount();
  await activateB();
  expect(requestIndex).toHaveBeenCalledTimes(2);
  expect(useSpringStore.getStore(WORKSPACE_B).getState().phase).toBe("ready");
  expect(useSpringStore.getStore(WORKSPACE_B).getState().index).toEqual(index(ROOT_A));
});

test("directory renames and removals refresh endpoints while unrelated workspaces stay ignored", async () => {
  await mount();
  requestIndex.mockClear();
  let currentFiles = files(ROOT_A);
  useFileSystemStore
    .getStore(WORKSPACE_A)
    .setState({ getAllProjectFiles: async () => currentFiles });

  await act(async () => {
    externalChange(`${ROOT_B}/src`, "deleted");
    externalChange(`${ROOT_A}/README.md`, "reloaded");
  });
  expect(scheduled).toHaveLength(0);

  // The watcher emits only directory paths for the two sides of a rename.
  currentFiles = [
    { name: "Controller.java", path: `${ROOT_A}/renamed/Controller.java`, isDir: false },
  ];
  await act(async () => {
    externalChange(`${ROOT_A}/src`, "deleted");
    externalChange(`${ROOT_A}/renamed`, "opened");
  });
  expect(scheduled.map((entry) => entry.cancelled)).toEqual([true, false]);
  await act(async () => {
    scheduled[1].reload();
  });
  expect(requestIndex.mock.calls[0][0].paths).toEqual(["renamed/Controller.java"]);

  currentFiles = [];
  await act(async () => {
    externalChange(`${ROOT_A}/renamed`, "deleted");
  });
  await act(async () => {
    scheduled[2].reload();
  });
  expect(useSpringStore.getStore(WORKSPACE_A).getState().index.endpoints).toEqual([]);
  expect(useSpringStore.getStore(WORKSPACE_A).getState().phase).toBe("ready");
});

test("a workspace rescan is coalesced and pending reloads are cancelled on unmount", async () => {
  await mount();
  await act(async () => {
    externalChange(ROOT_A, "rescan");
    externalChange(ROOT_A, "rescan");
  });
  expect(scheduled.map((entry) => entry.cancelled)).toEqual([true, false]);
  await act(async () => {
    root.render(null);
  });
  expect(scheduled[1].cancelled).toBe(true);
  externalChange(ROOT_A, "rescan");
  expect(scheduled).toHaveLength(2);
});

test("typing retains dependency metadata roots instead of falling back to built-in keys", async () => {
  dependencies.resolveMetadataRepository = async () => "C:/fixture/maven-repository";
  await mount();
  await act(async () => {
    externalChange(`${ROOT_A}/application.properties`, "reloaded");
  });
  await act(async () => {
    scheduled.slice(-1)[0]!.reload();
  });
  expect(requestIndex.mock.calls).toHaveLength(2);
  for (const [args] of requestIndex.mock.calls) {
    expect(args.metadataRepositories).toEqual(["C:/fixture/maven-repository"]);
  }
  expect(requestIndex.mock.calls[1][0].refreshDependencyMetadata).toBe(false);
});

test("JDT readiness requests a dependency refresh and its subscription is disposed", async () => {
  let ready: (() => void) | undefined;
  let disposed = false;
  dependencies.subscribeDependencyReady = (owner, reload) => {
    expect(owner).toBe(ROOT_A);
    ready = reload;
    return () => {
      disposed = true;
    };
  };
  await mount();
  await act(async () => {
    ready!();
  });
  await act(async () => {
    scheduled.slice(-1)[0]!.reload();
  });
  expect(requestIndex.mock.calls[1][0].refreshDependencyMetadata).toBe(true);
  await act(async () => {
    root.render(null);
  });
  expect(disposed).toBe(true);
  const count = scheduled.length;
  ready!();
  expect(scheduled).toHaveLength(count);
});

function useProductionReadyObserver() {
  const lookup = spyOn(lspAdapter, "getLspWorkspaceSessionSnapshot").mockImplementation(
    ({ workspacePath, languageId }) => ({
      id: workspacePath === ROOT_A ? "java-a" : "java-b",
      workspacePath,
      languageId,
      phase: "ready",
      operationId: "test-import",
      featureState: { phase: "unknown" },
    }),
  );
  restoreSessionLookup = () => lookup.mockRestore();
  dependencies.subscribeDependencyReady = subscribeSpringDependencyReady;
}

test("the production observer refreshes dependency metadata for serviceReady without double-refreshing its ready alias", async () => {
  useProductionReadyObserver();
  await mount();
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "serverConnected"),
  );
  expect(scheduled).toHaveLength(0);
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "serviceReady"),
  );
  expect(scheduled).toHaveLength(1);
  await act(async () => {
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "serviceReady");
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "fullyReady");
  });
  expect(scheduled).toHaveLength(1);
  await act(async () => scheduled[0].reload());
  expect(requestIndex.mock.calls[1][0].refreshDependencyMetadata).toBe(true);
  expect(requestIndex.mock.calls[1][0].root).toBe(ROOT_A);
  await act(async () => {
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "failed");
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "serviceReady");
  });
  expect(scheduled).toHaveLength(2);
  await act(async () => scheduled[1].reload());
  expect(requestIndex.mock.calls[2][0].refreshDependencyMetadata).toBe(true);
});

test("the production observer keeps legacy fullyReady compatibility and disposes its real subscription", async () => {
  useProductionReadyObserver();
  await mount();
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "fullyReady"),
  );
  expect(scheduled).toHaveLength(1);
  await act(async () => root.render(null));
  expect(scheduled[0].cancelled).toBe(true);
  await act(async () => {
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "failed");
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "fullyReady");
  });
  expect(scheduled).toHaveLength(1);
});

test("ready events from another or retired workspace do not refresh the active Spring owner", async () => {
  useProductionReadyObserver();
  await mount();
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("unrelated", "serviceReady"),
  );
  expect(scheduled).toHaveLength(0);
  await activateB();
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("java-a", "serviceReady"),
  );
  expect(scheduled).toHaveLength(0);
  await act(async () =>
    useLspStore.getState().actions.updateLanguageLifecycle("java-b", "serviceReady"),
  );
  expect(scheduled).toHaveLength(1);
  await act(async () => scheduled[0].reload());
  expect(requestIndex.mock.calls[requestIndex.mock.calls.length - 1]![0].root).toBe(ROOT_B);
  expect(
    requestIndex.mock.calls[requestIndex.mock.calls.length - 1]![0].refreshDependencyMetadata,
  ).toBe(true);
});
