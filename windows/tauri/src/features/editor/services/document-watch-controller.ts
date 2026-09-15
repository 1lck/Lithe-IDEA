import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { invoke } from "@/platform/tauri-core";
import { isLocalDocumentPath } from "@/platform/document-files";
import type { useBufferStore } from "../stores/buffer.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";

type BufferStore = ReturnType<typeof useBufferStore.getStore>;
type Target = { id: string; path: string; bufferId: string; store: BufferStore };
let generation = 0;
let dispose: (() => Promise<void>) | undefined;
const MAX_CONCURRENT_RECONCILIATIONS = 4;
const MAX_RECONCILIATION_PASSES = 4;

function scheduleNextReconciliation(callback: () => void) {
  const timer = setTimeout(callback, 0);
  return () => clearTimeout(timer);
}

export interface DocumentWatchDependencies {
  stores: () => BufferStore[];
  subscribe: (callback: () => void) => () => void;
  listen: (callback: (event: { generation: number; id: string }) => void) => Promise<UnlistenFn>;
  focus: (callback: () => void) => () => void;
  register: (generation: number, documents: { id: string; path: string }[]) => Promise<unknown>;
  schedule?: (callback: () => void) => () => void;
}

/** One controller per WebView; native leases are independently owned by its window. */
export async function createDocumentWatches(dependencies: DocumentWatchDependencies) {
  let stopped = false;
  let targets = new Map<string, Target>();
  const ids = new WeakMap<BufferStore, number>();
  let sequence = 0;
  let signature = "";
  const pending = new Set<string>();
  const running = new Set<string>();
  let registration = Promise.resolve();
  let unlisten: UnlistenFn | undefined;
  let cancelScheduledReconciliation: (() => void) | undefined;

  const canReconcile = (id: string) => {
    if (stopped || running.has(id) || running.size >= MAX_CONCURRENT_RECONCILIATIONS) return false;
    const target = targets.get(id);
    const buffer = target?.store.getState().buffers.find((candidate) => candidate.id === target.bufferId);
    return buffer?.type === "editor" && buffer.documentLifecycle?.status !== "saving";
  };
  const schedulePending = () => {
    if (cancelScheduledReconciliation || ![...pending].some(canReconcile)) return;
    // Yield between bounded bursts, but keep ownership of unfinished checks even
    // if the user stops editing and no further native event arrives.
    cancelScheduledReconciliation = (dependencies.schedule ?? scheduleNextReconciliation)(() => {
      cancelScheduledReconciliation = undefined;
      for (const id of [...pending]) if (canReconcile(id)) void reconcile(id);
    });
  };

  const reconcile = async (id: string) => {
    if (stopped) return;
    pending.add(id);
    if (!canReconcile(id)) return;
    running.add(id);
    try {
      for (let pass = 0; pass < MAX_RECONCILIATION_PASSES && pending.delete(id) && !stopped; pass++) {
        const target = targets.get(id);
        if (!target) break;
        const buffer = target.store.getState().buffers.find((candidate) => candidate.id === target.bufferId);
        if (buffer?.type !== "editor") break;
        if (buffer.documentLifecycle?.status === "saving") { pending.add(id); break; }
        const result = await target.store.getState().actions.handleExternalBufferChange(target.bufferId, crypto.randomUUID());
        if (stopped) break;
        if (result === "deferred") pending.add(id);
      }
    } finally {
      running.delete(id);
      for (const next of pending) {
        if (next !== id && canReconcile(next)) void reconcile(next);
      }
      schedulePending();
    }
  };
  const snapshot = (force = false) => {
    if (stopped) return;
    const next = new Map<string, Target>();
    for (const store of dependencies.stores()) {
      if (!ids.has(store)) ids.set(store, ++sequence);
      for (const buffer of store.getState().buffers) {
        if (buffer.type !== "editor" || buffer.isVirtual || buffer.readOnly || !isLocalDocumentPath(buffer.path)) continue;
        const id = `${ids.get(store)}:${buffer.id}`;
        next.set(id, { id, path: buffer.path, bufferId: buffer.id, store });
      }
    }
    const nextSignature = JSON.stringify([...next.values()].map(({ id, path }) => ({ id, path })));
    targets = next;
    for (const id of [...pending]) if (!targets.has(id)) pending.delete(id);
    if (force || signature !== nextSignature) {
      signature = nextSignature;
      const current = ++generation;
      const documents = [...targets.values()].map(({ id, path }) => ({ id, path }));
      registration = registration.then(async () => {
        if (stopped || current !== generation) return;
        try { await dependencies.register(current, documents); }
        catch (error) { console.error("Document watch registration failed; saving remains guarded", error); }
        if (!stopped && current === generation) for (const id of targets.keys()) void reconcile(id);
      });
    } else {
      for (const id of [...pending]) if (!running.has(id)) void reconcile(id);
    }
  };
  unlisten = await dependencies.listen((payload) => {
    if (!stopped && payload.generation === generation && targets.has(payload.id)) void reconcile(payload.id);
  });
  const unsubscribe = dependencies.subscribe(() => snapshot());
  const removeFocus = dependencies.focus(() => snapshot(true));
  snapshot(true);
  return async () => {
    stopped = true;
    cancelScheduledReconciliation?.();
    cancelScheduledReconciliation = undefined;
    unsubscribe(); unlisten?.(); removeFocus();
    targets.clear(); pending.clear();
    await registration;
    await dependencies.register(++generation, []);
  };
}
let lifecycle = Promise.resolve();
export function initializeDocumentWatches() {
  lifecycle = lifecycle.catch((error) => console.error("Document watch cleanup failed", error)).then(async () => {
    const previous = dispose; dispose = undefined;
    await previous?.();
    dispose = await createDocumentWatches({
      stores: () => workspaceRuntimeRegistry.getExistingStores<ReturnType<BufferStore["getState"]>>("editor-buffer"),
      subscribe: (callback) => workspaceRuntimeRegistry.subscribeToStoreKey("editor-buffer", callback),
      listen: (callback) => listen<{ generation: number; id: string }>("document-file-changed", ({ payload }) => callback(payload)),
      focus: (callback) => { window.addEventListener("focus", callback); return () => window.removeEventListener("focus", callback); },
      register: (generation, documents) => invoke("set_document_watches", { generation, documents }),
    });
  });
  return lifecycle;
}
export function cleanupDocumentWatches() {
  lifecycle = lifecycle.catch((error) => console.error("Document watch initialization failed", error)).then(async () => {
    const previous = dispose; dispose = undefined;
    await previous?.();
  });
  return lifecycle;
}
