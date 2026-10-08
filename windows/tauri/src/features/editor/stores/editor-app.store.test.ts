import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { toast } from "sonner";
import * as native from "@/platform/tauri-core";
import { saveActiveFileAs } from "@/features/keymaps/commands/file-command-actions";
import { applyWorkspaceEdit } from "../lsp/workspace-edit";
import { replaceAllInSources, replaceNextInSource } from "@/features/global-search/utils/source-replace";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { saveWorkspaceBeforeLaunch } from "../services/save-workspace-before-launch";
import { getBufferById } from "../utils/buffer-index";
import { useBufferStore } from "./buffer.store";
import { createEditorAppStore, useEditorAppStore } from "./editor-app.store";
import type { DocumentLifecycleDecision } from "@/platform/document-lifecycle";

const WORKSPACE_A = "editor-app-test-a";
const WORKSPACE_B = "editor-app-test-b";

function editorBuffer(
  id: string,
  content: string,
  options: { isDirty?: boolean; isPreview?: boolean; isVirtual?: boolean; path?: string } = {},
): EditorContent {
  const path =
    options.path ?? `${options.isVirtual === false ? "C:/workspace" : "virtual:"}/${id}.txt`;
  return {
    id,
    type: "editor",
    path,
    name: `${id}.txt`,
    content,
    savedContent: options.isDirty ? `${content}-saved` : content,
    isDirty: options.isDirty ?? false,
    isVirtual: options.isVirtual ?? true,
    isPinned: false,
    isPreview: options.isPreview ?? false,
    isActive: true,
    tokens: [],
  };
}

function setWorkspaceBuffers(
  workspaceId: string,
  buffers: EditorContent[],
  activeBufferId: string,
) {
  useBufferStore.getStore(workspaceId).setState({ buffers, activeBufferId });
}

function getEditorBuffer(workspaceId: string, bufferId: string): EditorContent {
  const buffer = getBufferById(useBufferStore.getStore(workspaceId).getState().buffers, bufferId);
  if (!buffer || buffer.type !== "editor") {
    throw new Error(`Expected editor buffer: ${bufferId}`);
  }
  return buffer;
}

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE_A, name: "Workspace A" }, "ready");
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");
});

afterEach(() => {
  useEditorAppStore.getStore(WORKSPACE_A).getState().actions.cleanup();
  useEditorAppStore.getStore(WORKSPACE_B).getState().actions.cleanup();
});

describe("workspace-scoped editor actions", () => {
  for (const operation of ["rename", "replace-all", "replace-next"] as const) {
    test(`${operation} rejects unloaded targets before changing other documents`, async () => {
      const a = editorBuffer("a", "old name", { path: "C:/fixture/a.txt", isVirtual: false });
      const b = editorBuffer("b", "", { path: "C:/fixture/b.txt", isVirtual: false });
      b.loadState = "loading";
      setWorkspaceBuffers(WORKSPACE_A, [a, b], a.id);
      workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_A, name: "Workspace A" }, "ready");
      const options = { caseSensitive: true, wholeWord: false, useRegex: false };
      const edit = { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 3 } }, newText: "new" };
      const task = operation === "rename"
        ? applyWorkspaceEdit({ changes: { "file:///C:/fixture/a.txt": [edit], "file:///C:/fixture/b.txt": [edit] } })
        : operation === "replace-all"
          ? replaceAllInSources([a.path, b.path], "old", "new", options)
          : replaceNextInSource({ filePath: b.path, line: 1, column: 1 }, "old", "new", options);
      await expect(task).rejects.toThrow("b.txt");
      expect(getEditorBuffer(WORKSPACE_A, a.id).content).toBe("old name");
      expect(getEditorBuffer(WORKSPACE_A, a.id).isDirty).toBe(false);
      expect(getEditorBuffer(WORKSPACE_A, b.id).content).toBe("");
    });
  }

  test("unrelated loading tabs do not block replacement or lose later edits", async () => {
    const a = editorBuffer("a", "old name", { path: "C:/fixture/a.txt", isVirtual: false });
    const b = editorBuffer("b", "", { path: "C:/fixture/b.txt", isVirtual: false });
    b.loadState = "loading";
    setWorkspaceBuffers(WORKSPACE_A, [a, b], a.id);
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_A, name: "Workspace A" }, "ready");
    expect(await replaceAllInSources([a.path], "old", "new", {
      caseSensitive: true, wholeWord: false, useRegex: false,
    })).toBe(1);
    const actions = useBufferStore.getStore(WORKSPACE_A).getState().actions;
    actions.replaceRestoredBufferContent(a.id, "stale content", "plaintext", undefined, undefined);
    expect(getEditorBuffer(WORKSPACE_A, a.id).content).toBe("new name");
    expect(getEditorBuffer(WORKSPACE_A, a.id).savedContent).toBe("old name");
    expect(getEditorBuffer(WORKSPACE_A, a.id).isDirty).toBe(true);
  });

  for (const loadState of ["unloaded", "loading", "error"] as const) {
    test(`rejects saving a remote ${loadState} placeholder before SSH writes`, async () => {
      const buffer = editorBuffer("remote", "", {
        path: "remote://test/work/source.txt", isVirtual: false,
      });
      buffer.loadState = loadState;
      setWorkspaceBuffers(WORKSPACE_A, [buffer], buffer.id);
      const failure = spyOn(toast, "error").mockImplementation(() => "test-toast");
      const invoke = spyOn(native, "invoke").mockResolvedValue(undefined);
      try {
        expect(await useEditorAppStore.getStore(WORKSPACE_A).getState().actions.handleSave())
          .toBe("failed");
        expect(getEditorBuffer(WORKSPACE_A, buffer.id).isDirty).toBe(false);
        expect(failure).toHaveBeenCalledTimes(1);
        expect(invoke).not.toHaveBeenCalled();
      } finally {
        invoke.mockRestore();
        failure.mockRestore();
      }
    });
  }

  test("save-as rejects a loading placeholder without writing a file", async () => {
    const buffer = editorBuffer("pending", "", { isVirtual: false });
    buffer.loadState = "loading";
    setWorkspaceBuffers(WORKSPACE_A, [buffer], buffer.id);
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_A, name: "Workspace A" }, "ready");
    const failure = spyOn(toast, "error").mockImplementation(() => "test-toast");
    const invoke = spyOn(native, "invoke").mockResolvedValue(undefined);
    try {
      await saveActiveFileAs();
      expect(invoke).not.toHaveBeenCalled();
      expect(failure).toHaveBeenCalledTimes(1);
    } finally {
      invoke.mockRestore();
      failure.mockRestore();
    }
  });

  test("routes content changes to the source workspace", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("a", "A original", { isVirtual: false })],
      "a",
    );
    setWorkspaceBuffers(WORKSPACE_B, [editorBuffer("b", "B original")], "b");
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("a", "A edited");

    expect(getEditorBuffer(WORKSPACE_A, "a").content).toBe("A edited");
    expect(getEditorBuffer(WORKSPACE_A, "a").contentRevision).toBe(1);
    expect(getEditorBuffer(WORKSPACE_A, "a").documentLifecycle).toEqual({
      status: "dirty",
      revision: 1,
      savedRevision: 0,
    });
    expect(getEditorBuffer(WORKSPACE_B, "b").content).toBe("B original");
  });

  test("routes content changes to the emitting buffer when another buffer is active", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("source", "Source original"), editorBuffer("active", "Active original")],
      "active",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("source", "Source edited");

    expect(getEditorBuffer(WORKSPACE_A, "source").content).toBe("Source edited");
    expect(getEditorBuffer(WORKSPACE_A, "active").content).toBe("Active original");
  });

  test("promotes an edited preview buffer before another preview can replace it", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [editorBuffer("preview", "Original", { isPreview: true, isVirtual: false })],
      "preview",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("preview", "Edited");

    const preview = getEditorBuffer(WORKSPACE_A, "preview");
    expect(preview.content).toBe("Edited");
    expect(preview.isPreview).toBe(false);
    expect(preview.isDirty).toBe(true);
  });

  test("keeps remote edits dirty until the remote write succeeds", async () => {
    setWorkspaceBuffers(
      WORKSPACE_A,
      [
        editorBuffer("remote", "Original", {
          isVirtual: false,
          path: "remote://connection/project/file.txt",
        }),
      ],
      "remote",
    );

    await useEditorAppStore
      .getStore(WORKSPACE_A)
      .getState()
      .actions.handleContentChange("remote", "Edited");

    const remoteBuffer = getEditorBuffer(WORKSPACE_A, "remote");
    expect(remoteBuffer.content).toBe("Edited");
    expect(remoteBuffer.isDirty).toBe(true);
  });

  test("saves only the explicitly targeted workspace buffer", async () => {
    setWorkspaceBuffers(WORKSPACE_A, [editorBuffer("a", "A edited", { isDirty: true })], "a");
    setWorkspaceBuffers(WORKSPACE_B, [editorBuffer("b", "B edited", { isDirty: true })], "b");
    workspaceRuntimeRegistry.activateWorkspace({ id: WORKSPACE_B, name: "Workspace B" }, "ready");

    const result = await useEditorAppStore.getStore(WORKSPACE_A).getState().actions.handleSave("a");

    const workspaceABuffer = getEditorBuffer(WORKSPACE_A, "a");
    const workspaceBBuffer = getEditorBuffer(WORKSPACE_B, "b");
    expect(result).toBe("saved");
    expect(workspaceABuffer.isDirty).toBe(false);
    expect(workspaceBBuffer.isDirty).toBe(true);
  });

  test("keeps failed saves dirty and reports the failure", async () => {
    const saveFailureToast = spyOn(toast, "error").mockImplementation(() => "test-toast");
    const expectedParseError = spyOn(console, "error").mockImplementation(() => undefined);
    setWorkspaceBuffers(
      WORKSPACE_A,
      [
        editorBuffer("settings", "not valid json", {
          isDirty: true,
          path: "settings://user-settings.json",
        }),
      ],
      "settings",
    );

    try {
      const result = await useEditorAppStore
        .getStore(WORKSPACE_A)
        .getState()
        .actions.handleSave("settings");

      expect(result).toBe("failed");
      expect(getEditorBuffer(WORKSPACE_A, "settings").isDirty).toBe(true);
      expect(saveFailureToast).toHaveBeenCalledTimes(1);
      expect(saveFailureToast.mock.calls[0]?.[0]).toContain("settings.txt");
    } finally {
      saveFailureToast.mockRestore();
      expectedParseError.mockRestore();
    }
  });

  test("saves only the target workspace before an external launch", async () => {
    setWorkspaceBuffers(WORKSPACE_A, [editorBuffer("a", "A edited", { isDirty: true })], "a");
    setWorkspaceBuffers(WORKSPACE_B, [editorBuffer("b", "B edited", { isDirty: true })], "b");

    await saveWorkspaceBeforeLaunch(WORKSPACE_A);

    expect(getEditorBuffer(WORKSPACE_A, "a").isDirty).toBe(false);
    expect(getEditorBuffer(WORKSPACE_B, "b").isDirty).toBe(true);
  });

  test("waits for an active auto-save before checking external launch readiness", async () => {
    setWorkspaceBuffers(WORKSPACE_A, [editorBuffer("a", "A edited", { isDirty: true })], "a");
    const bufferActions = useBufferStore.getStore(WORKSPACE_A).getState().actions;
    bufferActions.applyDocumentLifecycle("a", {
      status: "saving",
      revision: 1,
      savedRevision: 0,
      saveRevision: 1,
      operationId: "auto-save-a",
    });

    const launchSaveState: { value: "pending" | "resolved" | "rejected" } = {
      value: "pending",
    };
    const launchSave = saveWorkspaceBeforeLaunch(WORKSPACE_A).then(
      () => {
        launchSaveState.value = "resolved";
      },
      () => {
        launchSaveState.value = "rejected";
      },
    );
    await Promise.resolve();
    expect(launchSaveState.value).toBe("pending");

    bufferActions.recordSuccessfulBufferSave("a", "A edited", {
      status: "clean",
      revision: 1,
    });
    await launchSave;

    expect(launchSaveState.value).toBe("resolved");
  }, 1_000);

  test("rejects an external launch when a workspace file remains unsaved", async () => {
    const saveFailureToast = spyOn(toast, "error").mockImplementation(() => "test-toast");
    const expectedParseError = spyOn(console, "error").mockImplementation(() => undefined);
    setWorkspaceBuffers(
      WORKSPACE_A,
      [
        editorBuffer("settings", "not valid json", {
          isDirty: true,
          path: "settings://user-settings.json",
        }),
      ],
      "settings",
    );

    try {
      await expect(saveWorkspaceBeforeLaunch(WORKSPACE_A)).rejects.toThrow("settings.txt");
      expect(getEditorBuffer(WORKSPACE_A, "settings").isDirty).toBe(true);
    } finally {
      saveFailureToast.mockRestore();
      expectedParseError.mockRestore();
    }
  });
});

test.each([false, true])("guarded save preserves conflicts and does not revive a closed workspace (closed=%s)", async (closeWorkspace) => {
  const documentFiles = await import("@/platform/document-files");
  const lifecycle = await import("@/platform/document-lifecycle");
  const history = await import("@/features/local-history/api/local-history-api");
  const settings = await import("@/features/settings/stores/settings.store");
  const previousFormat = settings.useSettingsStore.getState().settings.formatOnSave;
  settings.useSettingsStore.setState((state) => ({ settings: { ...state.settings, formatOnSave: false } }));
  const save = spyOn(documentFiles, "saveDocumentFile").mockImplementation(async () => {
    if (closeWorkspace) workspaceRuntimeRegistry.removeWorkspace(WORKSPACE_A);
    return { status: "conflict", content: "external version" };
  });
  const record = spyOn(history, "recordLocalHistoryFile").mockResolvedValue(null);
  const decide = spyOn(lifecycle, "decideDocumentLifecycle").mockImplementation(async (state, event) => {
    if (event.type === "saveStarted") return { state: { status: "saving", revision: state.revision, savedRevision: 0, saveRevision: state.revision, operationId: event.operationId }, action: "writeToDisk" };
    if (event.type === "diskConflict") return { state: { status: "conflict", revision: state.revision, savedRevision: 0 }, action: "showConflict" };
    throw new Error(`Unexpected transition: ${event.type}`);
  });
  try {
    setWorkspaceBuffers(WORKSPACE_A, [editorBuffer("local", "my edits", { isVirtual: false, isDirty: true })], "local");
    const result = await useEditorAppStore.getStore(WORKSPACE_A).getState().actions.handleSave("local");
    expect(result).toBe("cancelled");
    expect(save).toHaveBeenCalledWith("C:/workspace/local.txt", "my edits", "my edits-saved");
    if (closeWorkspace) {
      expect(workspaceRuntimeRegistry.hasWorkspace(WORKSPACE_A)).toBe(false);
      return;
    }
    const buffer = getEditorBuffer(WORKSPACE_A, "local");
    expect(buffer.content).toBe("my edits");
    expect(buffer.externalDiskContent).toBe("external version");
    expect(buffer.documentLifecycle?.status).toBe("conflict");
    expect(buffer.isDirty).toBe(true);
  } finally {
    save.mockRestore(); record.mockRestore(); decide.mockRestore();
    settings.useSettingsStore.setState((state) => ({ settings: { ...state.settings, formatOnSave: previousFormat } }));
  }
});

/** Debounce timers advanced by the test instead of wall-clock delays. */
class ManualTimer {
  private nextId = 1;
  private readonly callbacks = new Map<number, () => void | Promise<void>>();

  readonly set = (callback: () => void | Promise<void>) => {
    const id = this.nextId++;
    this.callbacks.set(id, callback);
    return id as unknown as ReturnType<typeof setTimeout>;
  };

  readonly clear = (timer: ReturnType<typeof setTimeout>) => {
    this.callbacks.delete(timer as unknown as number);
  };

  get size(): number {
    return this.callbacks.size;
  }

  async fireNext(): Promise<void> {
    const id = [...this.callbacks.keys()].sort((left, right) => left - right)[0];
    if (id === undefined) throw new Error("No timer is scheduled.");
    const callback = this.callbacks.get(id);
    this.callbacks.delete(id);
    await callback?.();
  }
}

async function flushUntil(predicate: () => boolean, description: string): Promise<void> {
  for (let attempt = 0; attempt < 64; attempt += 1) {
    if (predicate()) return;
    await Promise.resolve();
  }
  throw new Error(`Autosave never reached: ${description}`);
}

interface PendingWrite {
  path: string;
  content: string;
  resolve: () => void;
  reject: (error: Error) => void;
}

/**
 * Autosave wiring for continuation tests: writes stay open until the test
 * releases them, the debounce runs on a manual timer, and the shared lifecycle
 * reducer is replaced so the tests do not depend on the Rust core.
 */
async function startAutosaveHarness() {
  const documentFiles = await import("@/platform/document-files");
  const lifecycle = await import("@/platform/document-lifecycle");
  const history = await import("@/features/local-history/api/local-history-api");
  const settings = await import("@/features/settings/stores/settings.store");
  const previousAutoSave = settings.useSettingsStore.getState().settings.autoSave;
  const previousFormatOnSave = settings.useSettingsStore.getState().settings.formatOnSave;
  settings.useSettingsStore.setState((state) => ({
    settings: { ...state.settings, autoSave: true, formatOnSave: false },
  }));

  const writes: PendingWrite[] = [];
  const save = spyOn(documentFiles, "saveDocumentFile").mockImplementation(
    async (path: string, content: string) => {
      await new Promise<void>((resolve, reject) => {
        writes.push({ path, content, resolve, reject });
      });
      return { status: "saved" };
    },
  );
  const record = spyOn(history, "recordLocalHistoryFile").mockResolvedValue(null);
  const failureToast = spyOn(toast, "error").mockImplementation(() => "test-toast");
  const failureLog = spyOn(console, "error").mockImplementation(() => undefined);
  const decide = spyOn(lifecycle, "decideDocumentLifecycle").mockImplementation(
    async (state, event): Promise<DocumentLifecycleDecision> => {
      if (event.type === "saveStarted") {
        if (state.status !== "dirty") {
          return { state, action: state.status === "conflict" ? "showConflict" : "none" };
        }
        return {
          state: {
            status: "saving",
            revision: state.revision,
            savedRevision: state.savedRevision,
            saveRevision: state.revision,
            operationId: event.operationId,
          },
          action: "writeToDisk",
        };
      }
      if (event.type === "saveSucceeded") {
        if (state.status !== "saving" || state.operationId !== event.operationId) {
          return { state, action: "ignoreStaleResult" };
        }
        return {
          state: state.revision === state.saveRevision
            ? { status: "clean", revision: state.revision }
            : { status: "dirty", revision: state.revision, savedRevision: state.saveRevision },
          action: "none",
        };
      }
      if (event.type === "saveFailed") {
        if (state.status !== "saving" || state.operationId !== event.operationId) {
          return { state, action: "reportSaveFailure" };
        }
        return {
          state: { status: "dirty", revision: state.revision, savedRevision: state.savedRevision },
          action: "reportSaveFailure",
        };
      }
      throw new Error(`Unexpected transition: ${event.type}`);
    },
  );

  const timer = new ManualTimer();
  // Save paths outside this store resolve it through the workspace registry, so
  // register the manual scheduler as the workspace factory to keep one instance.
  workspaceRuntimeRegistry.registerStore("editor-app", (id: string) =>
    createEditorAppStore(id, { setTimer: timer.set, clearTimer: timer.clear }),
  );
  const store = useEditorAppStore.getStore(WORKSPACE_A);
  return {
    timer,
    writes,
    store,
    save,
    failureToast,
    settings: settings.useSettingsStore,
    restore: () => {
      for (const write of writes) write.resolve();
      store.getState().actions.cleanup();
      save.mockRestore();
      record.mockRestore();
      decide.mockRestore();
      failureToast.mockRestore();
      failureLog.mockRestore();
      workspaceRuntimeRegistry.registerStore("editor-app", createEditorAppStore);
      settings.useSettingsStore.setState((state) => ({
        settings: { ...state.settings, autoSave: previousAutoSave, formatOnSave: previousFormatOnSave },
      }));
    },
  };
}

/** Queues one open write plus a newer edit whose debounce must wait for it. */
async function queueWriteAndNewerEdit(harness: Awaited<ReturnType<typeof startAutosaveHarness>>) {
  setWorkspaceBuffers(
    WORKSPACE_A,
    [editorBuffer("a", "first line", { path: "C:/workspace/a.txt", isVirtual: false })],
    "a",
  );
  const actions = harness.store.getState().actions;
  await actions.handleContentChange("a", "first line!");
  await flushUntil(() => harness.timer.size === 1, "the first debounce");
  await harness.timer.fireNext();
  await flushUntil(() => harness.writes.length === 1, "the first write request");
  expect(harness.writes[0]?.content).toBe("first line!");

  // The burst settles while that write still owns the document, so its own
  // debounce is refused and must be re-armed instead of dropped.
  await actions.handleContentChange("a", "first line!!");
  await flushUntil(() => harness.timer.size === 1, "the replacement debounce");
  await harness.timer.fireNext();
  await flushUntil(() => harness.timer.size === 1, "a debounce that continues the autosave");
  expect(harness.writes).toHaveLength(1);
  expect(getEditorBuffer(WORKSPACE_A, "a").isDirty).toBe(true);
}

describe("editor autosave continuation", () => {
  test("continues the delayed autosave while an earlier write is still in flight", async () => {
    const harness = await startAutosaveHarness();
    try {
      await queueWriteAndNewerEdit(harness);

      harness.writes[0]?.resolve();
      await flushUntil(
        () => getEditorBuffer(WORKSPACE_A, "a").documentLifecycle?.status === "dirty",
        "the first write to settle with newer text still pending",
      );
      await harness.timer.fireNext();
      await flushUntil(() => harness.writes.length === 2, "the continued write request");
      expect(harness.writes[1]?.content).toBe("first line!!");
      harness.writes[1]?.resolve();
      await flushUntil(() => !getEditorBuffer(WORKSPACE_A, "a").isDirty, "a saved document");

      expect(harness.save).toHaveBeenCalledTimes(2);
      expect(getEditorBuffer(WORKSPACE_A, "a").savedContent).toBe("first line!!");
    } finally {
      harness.restore();
    }
  }, 1_000);

  test("drops the queued continuation when the awaited write fails", async () => {
    const harness = await startAutosaveHarness();
    try {
      await queueWriteAndNewerEdit(harness);

      harness.writes[0]?.reject(new Error("disk full"));
      await flushUntil(
        () => getEditorBuffer(WORKSPACE_A, "a").documentLifecycle?.status === "dirty",
        "the failed write to restore dirty ownership",
      );

      const buffer = getEditorBuffer(WORKSPACE_A, "a");
      expect(harness.timer.size).toBe(0);
      expect(harness.writes).toHaveLength(1);
      expect(harness.failureToast).toHaveBeenCalledTimes(1);
      expect(buffer.isDirty).toBe(true);
      expect(buffer.content).toBe("first line!!");
    } finally {
      harness.restore();
    }
  }, 1_000);

  test("drops the queued continuation once autosave is switched off", async () => {
    const harness = await startAutosaveHarness();
    try {
      await queueWriteAndNewerEdit(harness);

      harness.settings.setState((state) => ({ settings: { ...state.settings, autoSave: false } }));
      harness.writes[0]?.resolve();
      await flushUntil(
        () => getEditorBuffer(WORKSPACE_A, "a").documentLifecycle?.status === "dirty",
        "the first write to settle with autosave already off",
      );
      await harness.timer.fireNext();
      // The queued continuation must be dropped instead of claiming a write.
      await flushUntil(
        () => Object.keys(harness.store.getState().autoSaveTasks).length === 0,
        "the queued continuation to be dropped once autosave is off",
      );

      const buffer = getEditorBuffer(WORKSPACE_A, "a");
      expect(harness.writes).toHaveLength(1);
      expect(buffer.isDirty).toBe(true);
      expect(buffer.content).toBe("first line!!");
    } finally {
      harness.restore();
    }
  }, 1_000);

  test("drops the queued continuation when a manual save fails", async () => {
    const harness = await startAutosaveHarness();
    try {
      setWorkspaceBuffers(
        WORKSPACE_A,
        [editorBuffer("a", "my edits", { isDirty: true, path: "C:/workspace/a.txt", isVirtual: false })],
        "a",
      );

      const manualSave = harness.store.getState().actions.handleSave("a");
      await flushUntil(
        () => getEditorBuffer(WORKSPACE_A, "a").documentLifecycle?.status === "saving",
        "the manual save to claim the document",
      );
      await flushUntil(() => harness.writes.length === 1, "the manual write request");
      const lifecycle = getEditorBuffer(WORKSPACE_A, "a").documentLifecycle;
      if (lifecycle?.status !== "saving") throw new Error("Expected the manual save to own the document.");
      harness.store.setState((state) => ({
        autoSaveTasks: {
          ...state.autoSaveTasks,
          a: {
            timeoutId: 1 as unknown as ReturnType<typeof setTimeout>,
            context: { bufferId: "a", path: "C:/workspace/a.txt", operationId: "continuation" },
            continuesOperationId: lifecycle.operationId,
          },
        },
      }));
      expect(harness.store.getState().autoSaveTasks.a).toBeDefined();

      harness.writes[0]?.reject(new Error("disk full"));

      await expect(manualSave).resolves.toBe("failed");
      expect(harness.store.getState().autoSaveTasks.a).toBeUndefined();
      expect(getEditorBuffer(WORKSPACE_A, "a").isDirty).toBe(true);
    } finally {
      harness.restore();
    }
  }, 1_000);
});
