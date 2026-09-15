import { expect, test } from "bun:test";
import { createDocumentWatches, type DocumentWatchDependencies } from "./document-watch-controller";

function harness() {
  let changed = () => {};
  let focus = () => {};
  let event = (_event: { generation: number; id: string }) => {};
  let checks = 0;
  let released = 0;
  const scheduled = new Set<() => void>();
  const gitChanges: unknown[] = [];
  const buffer = { id: "a", type: "editor", path: "C:/project/sub/A.java", documentLifecycle: { status: "clean" } };
  const state = { buffers: [buffer], actions: { handleExternalBufferChange: async () => { checks++; return "ignored"; } } };
  const store = { getState: () => state };
  const stores = [store];
  const registrations: { generation: number; documents: { id: string; path: string }[] }[] = [];
  const dependencies: DocumentWatchDependencies = {
    gitChanged: (change) => { gitChanges.push(change); },
    stores: () => stores as unknown as ReturnType<DocumentWatchDependencies["stores"]>,
    subscribe: (callback) => { changed = callback; return () => { released++; }; },
    focus: (callback) => { focus = callback; return () => { released++; }; },
    listen: async (callback) => { event = callback; return () => { released++; }; },
    register: async (generation, documents) => { registrations.push({ generation, documents }); },
    schedule: (callback) => { scheduled.add(callback); return () => { scheduled.delete(callback); }; },
  };
  return { gitChanges, dependencies, buffer, state, stores, registrations, changed: () => changed(), focus: () => focus(), event: (value: { generation: number; id: string }) => event(value), checks: () => checks, released: () => released,
    scheduledCount: () => scheduled.size,
    runScheduled: () => { const callbacks = [...scheduled]; scheduled.clear(); for (const callback of callbacks) callback(); },
  };
}
// The controller's chain is registration -> read -> completion; no native time or timers.
async function flush() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

test("watches all stores, reconciles after registration and releases subscriptions", async () => {
  const h = harness();
  h.stores.push({ getState: () => ({ ...h.state, buffers: [{ ...h.buffer, id: "b" }] }) });
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    expect(h.registrations[h.registrations.length - 1]?.documents).toHaveLength(2);
    expect(h.checks()).toBe(2);
    h.state.buffers = []; h.changed(); await flush();
    expect(h.registrations[h.registrations.length - 1]?.documents).toHaveLength(1);
  } finally { await dispose(); }
  expect(h.registrations[h.registrations.length - 1]?.documents).toEqual([]);
  expect(h.released()).toBe(3);
});

test("save completion reconciles an event deferred during save without a timer", async () => {
  const h = harness(); h.buffer.documentLifecycle.status = "saving";
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush(); expect(h.checks()).toBe(0);
    h.buffer.documentLifecycle.status = "dirty"; h.changed(); await flush();
    expect(h.checks()).toBe(1);
  } finally { await dispose(); }
});

test("focus renews leases and old generations cannot reload a relocated document", async () => {
  const h = harness(); const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush(); const old = h.registrations[h.registrations.length - 1]!;
    h.buffer.path = "C:/project/moved/A.java"; h.changed(); await flush();
    const before = h.checks();
    h.event({ generation: old.generation, id: old.documents[0]!.id }); await flush();
    expect(h.checks()).toBe(before);
    h.focus(); await flush();
    expect(h.registrations[h.registrations.length - 1]!.generation).toBeGreaterThan(old.generation);
    expect(h.checks()).toBe(before + 1);
  } finally { await dispose(); }
});

test("finishes a deferred burst after input stops without another notification", async () => {
  const h = harness();
  let attempts = 0;
  h.state.actions.handleExternalBufferChange = async () => {
    attempts++;
    if (attempts <= 4) {
      // The store changes while the read/decision is running, before it defers.
      h.changed();
      return "deferred";
    }
    return "conflict";
  };
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    expect(attempts).toBe(4);
    expect(h.scheduledCount()).toBe(1);
    h.runScheduled(); await flush();
    expect(attempts).toBe(5);
    expect(h.scheduledCount()).toBe(0);
  } finally { await dispose(); }
});

test("disposal cancels the continuation of an unfinished burst", async () => {
  const h = harness();
  let attempts = 0;
  h.state.actions.handleExternalBufferChange = async () => { attempts++; return "deferred"; };
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    expect(h.scheduledCount()).toBe(1);
  } finally { await dispose(); }
  expect(h.scheduledCount()).toBe(0);
  h.runScheduled(); await flush();
  expect(attempts).toBe(4);
});

test("a queued retry waits for a save and resumes when that save completes", async () => {
  const h = harness();
  let attempts = 0;
  h.state.actions.handleExternalBufferChange = async () => ++attempts <= 4 ? "deferred" : "ignored";
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    h.buffer.documentLifecycle.status = "saving"; h.changed();
    h.runScheduled(); await flush();
    expect(attempts).toBe(4);
    expect(h.scheduledCount()).toBe(0);
    h.buffer.documentLifecycle.status = "dirty"; h.changed(); await flush();
    expect(attempts).toBe(5);
  } finally { await dispose(); }
});

test("closing a document before its scheduled retry prevents another read", async () => {
  const h = harness();
  let attempts = 0;
  h.state.actions.handleExternalBufferChange = async () => { attempts++; return "deferred"; };
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    h.state.buffers = []; h.changed();
    h.runScheduled(); await flush();
    expect(attempts).toBe(4);
    expect(h.scheduledCount()).toBe(0);
  } finally { await dispose(); }
});

for (const result of ["reloaded", "conflict", "ignored", "failed"]) {
  test(`external ${result} sends only the required Git working-tree refresh`, async () => {
    const h = harness();
    h.buffer.path = "C:/project/tracked.txt";
    h.state.actions.handleExternalBufferChange = async () => result;
    const dispose = await createDocumentWatches(h.dependencies);
    try {
      await flush();
      expect(h.gitChanges).toEqual(result === "reloaded" || result === "conflict" ? [{
        filePath: h.buffer.path, scopes: ["working-tree"], source: "external-file-change",
      }] : []);
    } finally { await dispose(); }
  });
}

test("deferred reconciliation does not refresh Git until it completes", async () => {
  const h = harness();
  let result = "deferred";
  h.state.actions.handleExternalBufferChange = async () => result;
  const dispose = await createDocumentWatches(h.dependencies);
  try {
    await flush();
    expect(h.gitChanges).toEqual([]);
    result = "reloaded";
    h.runScheduled(); await flush();
    expect(h.gitChanges).toHaveLength(1);
  } finally { await dispose(); }
});
