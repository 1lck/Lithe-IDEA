import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as tauriEvents from "@tauri-apps/api/event";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as events from "../events/git-events";
import { useRepositoryStore } from "../stores/git-repository.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { GitWorkingTreeChangeHost } from "./git-working-tree-change-host";

const repo = "C:/fixture";

type FileChangeListener = (event: { payload: { path: string; event_type: string } }) => void;

let restoreDom: () => void;
let previousCustomEvent: typeof CustomEvent;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let previousRepositories: ReturnType<typeof useRepositoryStore.getState>;
let container: HTMLDivElement;
let root: Root | undefined;
let onFileChange!: FileChangeListener;
let unlisten: ReturnType<typeof mock<() => void>>;
const spies: Array<{ mockRestore: () => void }> = [];
let emitGitChanged: ReturnType<typeof mock<(change: events.GitChange) => void>>;

beforeEach(() => {
  restoreDom = installHappyDom();
  previousCustomEvent = globalThis.CustomEvent;
  globalThis.CustomEvent = window.CustomEvent;
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousRepositories = useRepositoryStore.getState();
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "ready");
  useRepositoryStore.getState().actions.reset();
  useRepositoryStore.getState().actions.setManualRepository(repo);
  emitGitChanged = mock(() => {});
  unlisten = mock(() => {});
  spies.push(
    spyOn(events, "emitGitChanged").mockImplementation(emitGitChanged as typeof events.emitGitChanged),
    spyOn(tauriEvents, "listen").mockImplementation((async (_event, listener) => {
      onFileChange = listener as FileChangeListener;
      return unlisten;
    }) as typeof tauriEvents.listen),
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
    useRepositoryStore.setState(previousRepositories, true);
    workspaceRuntimeRegistry.resetForTests();
    globalThis.CustomEvent = previousCustomEvent;
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
});

async function mount() {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root!.render(<GitWorkingTreeChangeHost />);
  });
}

async function emitFileChange(path: string, event_type: string) {
  await act(async () => {
    onFileChange({ payload: { path, event_type } });
  });
}

test("working-tree changes inside a repository emit a passive working-tree Git change", async () => {
  await mount();
  await emitFileChange(`${repo}/src/main.rs`, "reloaded");
  expect(emitGitChanged).toHaveBeenCalledWith({
    repoPath: repo,
    filePath: `${repo}/src/main.rs`,
    scopes: ["working-tree"],
    source: "external-file-change",
  });
  await emitFileChange(`${repo}/new-file.txt`, "opened");
  expect(emitGitChanged).toHaveBeenCalledTimes(2);
  await emitFileChange(`${repo}/gone.txt`, "deleted");
  expect(emitGitChanged).toHaveBeenCalledTimes(3);
});

test("changes inside .git and unrelated paths do not emit Git changes", async () => {
  await mount();
  await emitFileChange(`${repo}/.git/HEAD`, "reloaded");
  await emitFileChange(`${repo}/.git`, "reloaded");
  await emitFileChange(`${repo}/.git/index.lock`, "reloaded");
  await emitFileChange("D:/elsewhere/notes.md", "reloaded");
  expect(emitGitChanged).not.toHaveBeenCalled();
});

test(".gitignore edits reach Git because they reclassify untracked files", async () => {
  await mount();
  await emitFileChange(`${repo}/.gitignore`, "reloaded");
  expect(emitGitChanged).toHaveBeenCalledWith({
    repoPath: repo,
    filePath: `${repo}/.gitignore`,
    scopes: ["working-tree"],
    source: "external-file-change",
  });
});

test("rescan events are not forwarded", async () => {
  await mount();
  await emitFileChange(repo, "rescan");
  expect(emitGitChanged).not.toHaveBeenCalled();
});

test("background workspace repositories are covered and unmount detaches the listener", async () => {
  const background = workspaceRuntimeRegistry.ensureWorkspace(
    { id: "git-background", name: "background" },
    "ready",
  );
  useRepositoryStore.getStore(background.descriptor.id).setState({
    availableRepoPaths: ["D:/background"],
    activeRepoPath: "D:/background",
  });
  await mount();
  await emitFileChange("D:/background/other/src/lib.rs", "reloaded");
  expect(emitGitChanged).toHaveBeenCalledWith({
    repoPath: "D:/background",
    filePath: "D:/background/other/src/lib.rs",
    scopes: ["working-tree"],
    source: "external-file-change",
  });
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  expect(unlisten).toHaveBeenCalledTimes(1);
});
