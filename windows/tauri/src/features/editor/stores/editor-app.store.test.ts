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
import { useEditorAppStore } from "./editor-app.store";

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
