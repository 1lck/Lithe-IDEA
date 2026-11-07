import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import * as deferredWork from "@/features/editor/lsp/deferred-lsp-work";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { resolveEditorLspSupport } from "@/features/editor/lsp/built-in-language-support";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { useLspIntegration } = await import("./use-lsp-integration");

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

function Editor({ path, bufferId }: { path?: string; bufferId?: string }) {
  useLspIntegration({ filePath: path, bufferId });
  return null;
}

interface Start {
  scope: WorkspaceLaunchScope;
  id: string;
  gate: ReturnType<typeof deferred>;
}

async function fixture(run: (f: {
  path: string;
  starts: Start[];
  opened: Array<{ id: string; content: string }>;
  stopped: string[];
  closed: string[];
  closeGate: ReturnType<typeof deferred>;
  render: (id?: string) => Promise<void>;
  paint: () => Promise<void>;
  finish: (index: number) => Promise<void>;
  activate: (active: boolean) => void;
  switchWorkspace: () => Promise<void>;
  hideKeepingBuffer: () => Promise<void>;
}) => Promise<void>) {
  const suffix = crypto.randomUUID();
  const pluginId = `io.example.lifecycle-${suffix}`;
  const path = `C:/fixture/${suffix}.lifecycle`;
  const originalWorkspace = workspaceRuntimeRegistry.getActiveWorkspace();
  const scope = { workspaceId: `lifecycle-${suffix}`, root: "C:/fixture" };
  const other = { workspaceId: `other-${suffix}`, root: "C:/other" };
  let currentScope = scope;
  let active = true;
  const starts: Start[] = [];
  const opened: Array<{ id: string; content: string }> = [];
  const stopped: string[] = [];
  const closed: string[] = [];
  const closeGate = deferred();
  const scheduled = new Set<() => void>();
  const scheduling = spyOn(deferredWork, "deferUntilAfterNextPaint").mockImplementation((callback) => {
    scheduled.add(callback);
    return () => { scheduled.delete(callback); };
  });
  const client = {
    startForFile: async (_path: string, ownerScope: WorkspaceLaunchScope, _intent: unknown, id?: string) => {
      const start = { scope: ownerScope, id: id ?? `legacy-${starts.length}`, gate: deferred() };
      starts.push(start);
      await start.gate.promise;
      return { kind: "attached", attachmentId: start.id };
    },
    notifyDocumentOpen: async (_path: string, content: string, id: string) => { opened.push({ content, id }); },
    notifyDocumentClose: async (_path: string, id: string) => { closed.push(id); await closeGate.promise; },
    stopForFile: async (_path: string, id: string) => { stopped.push(id); },
  } as unknown as LspClient;
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const invoke = spyOn(native, "invoke").mockImplementation(async <T,>(command: string): Promise<T> => {
    if (command !== "declarative_plugins_language_owner") throw new Error(`unexpected ${command}`);
    return (active ? { pluginId, displayName: "Lifecycle fixture", languageId: "lifecycle" } : null) as T;
  });
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  const root = createRoot(host);
  function setWorkspace(next: WorkspaceLaunchScope) {
    currentScope = next;
    workspaceRuntimeRegistry.activateWorkspace({ id: next.workspaceId, name: "Fixture", path: next.root }, "ready");
    useFileSystemStore.getStore(next.workspaceId).setState({ rootFolderPath: next.root });
  }
  async function render(id?: string) {
    await act(async () => {
      useBufferStore.getStore(currentScope.workspaceId).setState({
        buffers: id ? [createPaneContent(id, {
          type: "editor", path, name: "fixture.lifecycle", content: currentScope.root,
        })] : [], activeBufferId: id ?? null,
      });
      root.render(<Editor path={id ? path : undefined} bufferId={id} />);
    });
  }
  async function paint() {
    await act(async () => {
      const callbacks = [...scheduled]; scheduled.clear();
      for (const callback of callbacks) callback();
    });
  }
  try {
    setPluginActive(pluginId, true);
    setWorkspace(scope);
    await resolveEditorLspSupport(path);
    await run({ path, starts, opened, stopped, closed, closeGate, render, paint,
      finish: async (index) => { await act(async () => starts[index].gate.resolve()); },
      activate: (value) => { active = value; setPluginActive(pluginId, value); },
      switchWorkspace: async () => { await act(async () => setWorkspace(other)); },
      hideKeepingBuffer: async () => { await act(async () => root.render(<Editor />)); },
    });
  } finally {
    closeGate.resolve();
    await act(async () => {
      for (const start of starts) start.gate.resolve();
      for (const ownerScope of [scope, other]) {
        useBufferStore.getStore(ownerScope.workspaceId).setState({ buffers: [], activeBufferId: null });
      }
      root.unmount();
    });
    setPluginActive(pluginId, false);
    scheduled.clear();
    instance.mockRestore(); invoke.mockRestore(); scheduling.mockRestore();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    if (originalWorkspace) workspaceRuntimeRegistry.activateWorkspace(originalWorkspace.descriptor, originalWorkspace.status);
    workspaceRuntimeRegistry.removeWorkspace(scope.workspaceId);
    workspaceRuntimeRegistry.removeWorkspace(other.workspaceId);
    host.remove();
  }
}

test("restored editor closes during attach and immediately reopens with a new owner", async () => {
  await fixture(async (f) => {
    await f.render("restored"); await f.paint();
    expect(f.starts.length).toBe(1);
    await f.render();
    await f.render("reopened"); await f.paint();
    expect(f.starts.length).toBe(2);
    expect(f.stopped).toContain(f.starts[0].id);
    expect(f.starts[1].id).not.toBe(f.starts[0].id);
    await f.finish(1); await f.finish(0);
    expect(f.opened.map((item) => item.id)).toEqual([f.starts[1].id]);
    expect(f.stopped).not.toContain(f.starts[1].id);
  });
}, 3000);

test("a batched same-path close/reopen replaces the buffer owner even without an intermediate render", async () => {
  await fixture(async (f) => {
    await f.render("old-buffer"); await f.paint(); await f.finish(0);
    await f.render("new-buffer"); await f.paint();
    expect(f.starts.length).toBe(2);
    await f.finish(1);
    // The old document close completes after the new document is already open.
    expect(f.closed).toEqual([f.starts[0].id]);
    await act(async () => f.closeGate.resolve());
    expect(f.opened.map((item) => item.id)).toEqual(f.starts.map((item) => item.id));
    expect(f.stopped).toContain(f.starts[0].id);
    expect(f.stopped).not.toContain(f.starts[1].id);
  });
}, 3000);

test("multiple rapid reopens cannot publish the earlier deferred attachments", async () => {
  await fixture(async (f) => {
    for (const id of ["first", "second", "third"]) { await f.render(id); await f.paint(); }
    expect(f.starts.length).toBe(3);
    await f.finish(2); await f.finish(0); await f.finish(1);
    expect(f.opened.map((item) => item.id)).toEqual([f.starts[2].id]);
    expect(f.stopped).not.toContain(f.starts[2].id);
  });
}, 3000);

test("reselecting an open buffer reschedules a cancelled paint but retains a running attachment", async () => {
  await fixture(async (f) => {
    await f.render("kept-buffer");
    await f.hideKeepingBuffer();
    await f.render("kept-buffer"); await f.paint();
    expect(f.starts.length).toBe(1);
    await f.finish(0);
    await f.hideKeepingBuffer(); await f.render("kept-buffer"); await f.paint();
    expect(f.starts.length).toBe(1);
    expect(f.opened.map((item) => item.id)).toEqual([f.starts[0].id]);
    expect(f.stopped).toEqual([]);
  });
}, 3000);

test("another plugin's catalog revision does not replace this editor's live registration", async () => {
  await fixture(async (f) => {
    const unrelated = `io.example.unrelated-${crypto.randomUUID()}`;
    try {
      await f.render("kept-buffer"); await f.paint(); await f.finish(0);
      await act(async () => { setPluginActive(unrelated, false); setPluginActive(unrelated, true); });
      await f.paint();
      expect(f.starts.length).toBe(1);
      expect(f.stopped).toEqual([]);
    } finally { await act(async () => setPluginActive(unrelated, false)); }
  });
}, 3000);

test("plugin disable revokes a pending owner and re-enable activates the still-open buffer", async () => {
  await fixture(async (f) => {
    await f.render("kept-buffer"); await f.paint();
    await act(async () => f.activate(false));
    await f.finish(0);
    expect(f.opened).toEqual([]);
    expect(f.stopped).toContain(f.starts[0].id);
    await act(async () => { f.activate(true); await resolveEditorLspSupport(f.path); });
    await f.paint();
    expect(f.starts.length).toBe(2);
    await f.finish(1);
    expect(f.opened.map((item) => item.id)).toEqual([f.starts[1].id]);
  });
}, 3000);

test.each(["update", "rollback"])("batched plugin %s reactivates an existing open editor with fresh registration", async () => {
  await fixture(async (f) => {
    await f.render("kept-buffer"); await f.paint(); await f.finish(0);
    await act(async () => {
      f.activate(false); f.activate(true);
      await resolveEditorLspSupport(f.path);
    });
    await f.paint();
    expect(f.starts.length).toBe(2);
    await f.finish(1);
    await act(async () => f.closeGate.resolve());
    expect(f.opened.map((item) => item.id)).toEqual(f.starts.map((item) => item.id));
    expect(f.stopped).toContain(f.starts[0].id);
    expect(f.stopped).not.toContain(f.starts[1].id);
  });
}, 3000);

test("a workspace switch keeps lookup, document text, and late cleanup in their captured scopes", async () => {
  await fixture(async (f) => {
    await f.render("old-workspace"); await f.paint();
    await f.switchWorkspace(); await f.render("new-workspace"); await f.paint();
    expect(f.starts.length).toBe(2);
    expect(f.starts[0].scope.workspaceId).not.toBe(f.starts[1].scope.workspaceId);
    await f.finish(1); await f.finish(0);
    expect(f.opened).toEqual([{ id: f.starts[1].id, content: "C:/other" }]);
    expect(f.stopped).not.toContain(f.starts[1].id);
  });
}, 3000);
