import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import * as adapter from "@/platform/lsp-core-adapter";
import * as launchResolver from "@/features/editor/lsp/resolve-editor-lsp-launch";
import * as deferredWork from "@/features/editor/lsp/deferred-lsp-work";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { resolveEditorLspSupport } from "@/features/editor/lsp/built-in-language-support";
import {
  flushLspDocumentChanges,
  queueLspDocumentChanges,
  takeLspDocumentChanges,
} from "@/features/editor/lsp/pending-document-changes";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { useLspIntegration } = await import("./use-lsp-integration");

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test("a hidden workspace's in-flight flusher cannot borrow a newer same-path attachment", async () => {
  const suffix = crypto.randomUUID();
  const path = `C:/fixture/${suffix}.queuedowner`;
  const pluginId = `io.example.queued-owner-${suffix}`;
  const first = { id: `first-${suffix}`, name: "First", path: "C:/first" };
  const second = { id: `second-${suffix}`, name: "Second", path: "C:/second" };
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspace();
  const scheduled = new Set<() => void>();
  const gate = deferred(),
    entered = deferred();
  const changes: Array<{ attachmentId: string; content: string }> = [];
  const documents = new Map();
  const fileAttachmentIds = new Map<string, string>();
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    fileAttachmentIds,
    documents,
    failedLanguageServers: new Map(),
    fileStartTasks: new Map(),
    workspaceStartTasks: new Map(),
    documentOpenTasks: new Map(),
    documentChangeTasks: new Map(),
    activeLanguageServers: new Set(),
    activeLanguages: new Set(),
    activeServerFiles: new Map(),
    serverScopes: new Map(),
    workspaceRepresentativeFiles: new Map(),
    repairLanguageServerPromises: new Map(),
  });
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  const resolve = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue({
    providerId: pluginId,
    pluginId,
    languageId: "queuedowner",
    serverPath: "C:/fixture/server.exe",
    serverArgs: [],
  });
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T,>(command: string): Promise<T> => {
      if (command !== "declarative_plugins_language_owner")
        throw new Error(`unexpected ${command}`);
      return { pluginId, languageId: "queuedowner", displayName: "Fixture" } as T;
    },
  );
  const transport = spyOn(adapter, "invokeLsp").mockImplementation(
    async <T,>(command: string, input?: unknown): Promise<T> => {
      const args = input as { attachmentId: string; content: string };
      if (command === "lsp_document_change") {
        changes.push({ attachmentId: args.attachmentId, content: args.content });
        if (changes.length === 1) {
          entered.resolve();
          await gate.promise;
        }
      }
      return undefined as T;
    },
  );
  const scheduling = spyOn(deferredWork, "deferUntilAfterNextPaint").mockImplementation(
    (callback) => {
      scheduled.add(callback);
      return () => {
        scheduled.delete(callback);
      };
    },
  );
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const root = createRoot(document.createElement("div"));
  const pending: Promise<void>[] = [];
  function Editor({ enabled, id }: { enabled: boolean; id: string }) {
    useLspIntegration({ enabled, filePath: path, bufferId: id });
    return null;
  }
  async function render(active: "first" | "second") {
    await act(async () => {
      root.render(
        <>
          <WorkspaceStoreScopeContext.Provider value={first.id}>
            <Editor enabled={active === "first"} id="first-buffer" />
          </WorkspaceStoreScopeContext.Provider>
          <WorkspaceStoreScopeContext.Provider value={second.id}>
            <Editor enabled={active === "second"} id="second-buffer" />
          </WorkspaceStoreScopeContext.Provider>
        </>,
      );
    });
    await act(async () => {
      for (const callback of scheduled) {
        scheduled.delete(callback);
        callback();
      }
    });
  }
  function update(workspaceId: string, content: string) {
    const store = useBufferStore.getStore(workspaceId);
    const previousContent =
      store.getState().buffers.find((buffer) => buffer.type === "editor")?.content ?? "";
    store.setState({
      buffers: store
        .getState()
        .buffers.map((buffer) => (buffer.type === "editor" ? { ...buffer, content } : buffer)),
    });
    queueLspDocumentChanges(path, [
      {
        rangeOffset: 0,
        rangeLength: previousContent.length,
        startLine: 1,
        startColumn: 1,
        endLine: 1,
        endColumn: previousContent.length + 1,
        text: content,
      },
    ]);
  }
  try {
    setPluginActive(pluginId, true);
    for (const workspace of [first, second]) {
      workspaceRuntimeRegistry.activateWorkspace(workspace, "ready");
      useFileSystemStore.getStore(workspace.id).setState({ rootFolderPath: workspace.path });
      useBufferStore.getStore(workspace.id).setState({
        buffers: [
          createPaneContent(`${workspace === first ? "first" : "second"}-buffer`, {
            type: "editor",
            path,
            name: "fixture.queuedowner",
            content: `${workspace.name} original`,
          }),
        ],
      });
    }
    workspaceRuntimeRegistry.activateWorkspace(first, "ready");
    await resolveEditorLspSupport(path);
    await render("first");
    await act(async () => update(first.id, "First edit 1"));
    const flushing = flushLspDocumentChanges(path);
    pending.push(flushing);
    await entered.promise;
    await act(async () => update(first.id, "First queued obsolete text"));
    const queued = flushLspDocumentChanges(path);
    pending.push(queued);
    await act(async () => workspaceRuntimeRegistry.activateWorkspace(second, "ready"));
    await render("second");
    const replacement = fileAttachmentIds.get(path.toLowerCase());
    await act(async () => {
      gate.resolve();
      await Promise.all(pending);
    });
    expect(changes.map((change) => change.content)).toEqual(["First edit 1"]);
    expect(changes[0].attachmentId).not.toBe(replacement);
    expect(documents.get(path.toLowerCase())?.content).toBe("Second original");
    // Manual restart legitimately replaces the attachment while this editor
    // effect stays mounted. Its current flusher must keep working afterwards.
    await client.restartForFile(
      path,
      { workspaceId: second.id, root: second.path },
      "Second original",
    );
    await act(async () => update(second.id, "Second edit after restart"));
    const currentFlush = flushLspDocumentChanges(path);
    pending.push(currentFlush);
    await currentFlush;
    expect(changes.map((change) => change.content)).toEqual([
      "First edit 1",
      "Second edit after restart",
    ]);
    expect(documents.get(path.toLowerCase())?.content).toBe("Second edit after restart");
  } finally {
    gate.resolve();
    await Promise.allSettled(pending);
    takeLspDocumentChanges(path);
    await act(async () => {
      for (const workspace of [first, second])
        useBufferStore.getStore(workspace.id).setState({ buffers: [] });
      root.unmount();
    });
    setPluginActive(pluginId, false);
    instance.mockRestore();
    snapshot.mockRestore();
    resolve.mockRestore();
    invoke.mockRestore();
    transport.mockRestore();
    scheduling.mockRestore();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    if (previousWorkspace)
      workspaceRuntimeRegistry.activateWorkspace(
        previousWorkspace.descriptor,
        previousWorkspace.status,
      );
    workspaceRuntimeRegistry.removeWorkspace(first.id);
    workspaceRuntimeRegistry.removeWorkspace(second.id);
  }
}, 3000);
