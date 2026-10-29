import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import * as launchResolver from "./resolve-editor-lsp-launch";
import { LspClient } from "./lsp-client";
import { useLspStore } from "./stores/lsp.store";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";

const path = "C:/fixture/acceptance.litheaccept";
const scope = { workspaceId: "lifecycle", root: "C:/fixture" };
const launch: launchResolver.EditorLspLaunch = {
  providerId: "io.example.lifecycle", pluginId: "io.example.lifecycle",
  languageId: "litheaccept", serverPath: "C:/fixture/server.exe", serverArgs: [],
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function clientFixture() {
  // Keep production attachment/document methods; native listeners are not
  // installed by these isolated ownership tests.
  const client = Object.create(LspClient.prototype) as LspClient;
  const fileAttachmentIds = new Map<string, string>();
  const documents = new Map();
  const failedLanguageServers = new Map<string, number>();
  Object.assign(client, {
    fileAttachmentIds, documents, failedLanguageServers,
    fileStartTasks: new Map(), workspaceStartTasks: new Map(),
    documentOpenTasks: new Map(), documentChangeTasks: new Map(),
    activeLanguageServers: new Set(), activeLanguages: new Set(),
    activeServerFiles: new Map(), serverScopes: new Map(),
    workspaceRepresentativeFiles: new Map(), repairLanguageServerPromises: new Map(),
  });
  return { client, fileAttachmentIds, documents, failedLanguageServers };
}

function nativeSpy(handler: (command: string, args: Record<string, unknown>) => Promise<unknown>) {
  return spyOn(adapter, "invokeLsp").mockImplementation(async <T,>(command: string, args?: unknown) =>
    await handler(command, args as Record<string, unknown>) as T);
}

test("closing during lookup cannot lend its pending start to the immediately reopened editor", async () => {
  const { client, documents } = clientFixture();
  const oldLookup = deferred<launchResolver.EditorLspLaunch>();
  const lookedUp = deferred<void>();
  let lookups = 0;
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockImplementation(async () => {
    if (++lookups === 1) { lookedUp.resolve(); return oldLookup.promise; }
    return launch;
  });
  const starts: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_start_for_file") starts.push(args.attachmentId);
  });
  const old = client.startForFile(path, scope, "attach", "closed-editor");
  const tasks: Promise<unknown>[] = [old];
  try {
    await lookedUp.promise;
    tasks.push(client.stopForFile(path, "closed-editor"));
    const reopened = client.startForFile(path, scope, "attach", "reopened-editor");
    tasks.push(reopened);
    oldLookup.resolve(launch);
    expect(await old).toEqual({ kind: "cancelled", reason: "superseded" });
    expect(await reopened).toEqual({ kind: "attached", attachmentId: "reopened-editor" });
    await client.notifyDocumentOpen(path, "restored then reopened", "reopened-editor");
    expect(starts).toEqual(["reopened-editor"]);
    expect(documents.get(path.toLowerCase())?.attachmentId).toBe("reopened-editor");
  } finally {
    oldLookup.resolve(launch);
    await Promise.allSettled(tasks);
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);

test.each(["before", "after"])("old detach completing %s the new attach preserves the new document", async (order) => {
  const { client, documents, fileAttachmentIds } = clientFixture();
  const oldStart = deferred<void>();
  const started = deferred<void>();
  const oldDetach = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const opens: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_start_for_file" && args.attachmentId === "old") {
      started.resolve(); await oldStart.promise;
    }
    if (command === "lsp_stop_for_file" && args.attachmentId === "old") await oldDetach.promise;
    if (command === "lsp_document_open") opens.push(args.attachmentId);
  });
  const old = client.startForFile(path, scope, "attach", "old");
  const tasks: Promise<unknown>[] = [old];
  try {
    await started.promise;
    const stopping = client.stopForFile(path, "old");
    tasks.push(stopping);
    if (order === "before") { oldDetach.resolve(); await stopping; }
    const current = client.startForFile(path, scope, "attach", "current");
    tasks.push(current);
    expect(await current).toEqual({ kind: "attached", attachmentId: "current" });
    await client.notifyDocumentOpen(path, "new content", "current");
    oldStart.resolve(); oldDetach.resolve();
    expect(await old).toEqual({ kind: "cancelled", reason: "superseded" });
    await stopping;
    expect(fileAttachmentIds.get(path.toLowerCase())).toBe("current");
    expect(documents.get(path.toLowerCase())?.content).toBe("new content");
    expect(opens).toEqual(["current"]);
  } finally {
    oldStart.resolve(); oldDetach.resolve();
    await Promise.allSettled(tasks);
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);

test("an explicit editor generation reattaches to an already running server with its own identity", async () => {
  const { client, fileAttachmentIds } = clientFixture();
  const key = path.toLowerCase();
  fileAttachmentIds.set(key, "previous-editor");
  Object.assign(client, { serverScopes: new Map([[`${scope.root}:litheaccept`, scope]]) });
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue({
    id: "existing", workspacePath: scope.root, languageId: "litheaccept", phase: "ready",
    operationId: "existing-start", featureState: { phase: "unknown" },
  });
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const starts: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_start_for_file") starts.push(args.attachmentId);
  });
  try {
    expect(await client.startForFile(path, scope, "attach", "new-editor"))
      .toEqual({ kind: "attached", attachmentId: "new-editor" });
    await client.stopForFile(path, "previous-editor");
    expect(fileAttachmentIds.get(key)).toBe("new-editor");
    expect(starts).toEqual(["new-editor"]);
  } finally { native.mockRestore(); resolver.mockRestore(); snapshot.mockRestore(); }
}, 2000);

test("a superseded native start failure cannot cool down the new editor's server", async () => {
  const { client, failedLanguageServers } = clientFixture();
  const failed = deferred<void>();
  const started = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_start_for_file" && args.attachmentId === "old") {
      started.resolve(); await failed.promise;
    }
  });
  const old = client.startForFile(path, scope, "attach", "old");
  try {
    await started.promise;
    expect(await client.startForFile(path, scope, "attach", "new"))
      .toEqual({ kind: "attached", attachmentId: "new" });
    failed.reject(new Error("obsolete native start failed"));
    expect(await old).toEqual({ kind: "cancelled", reason: "superseded" });
    expect(failedLanguageServers.size).toBe(0);
  } finally {
    failed.resolve(); await Promise.allSettled([old]);
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);

test.each([
  { workspaceId: "another-workspace", root: scope.root },
  { workspaceId: scope.workspaceId, root: "C:/replacement" },
])("a delayed buffer stop from scope %j cannot revoke the current editor", async (oldScope) => {
  const { client, fileAttachmentIds } = clientFixture();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const stopped: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_stop_for_file") stopped.push(args.attachmentId);
  });
  try {
    await client.startForFile(path, scope, "attach", "current");
    await client.stopForFile(path, undefined, oldScope);
    expect(stopped).toEqual([]);
    expect(fileAttachmentIds.get(path.toLowerCase())).toBe("current");
    await client.stopForFile(path, undefined, scope);
    expect(stopped).toEqual(["current"]);
    expect(fileAttachmentIds.size).toBe(0);
  } finally { native.mockRestore(); resolver.mockRestore(); }
}, 2000);

test("a late document close cannot erase the reopened document", async () => {
  const { client, documents } = clientFixture();
  const closing = deferred<void>();
  const entered = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_document_close" && args.attachmentId === "old") {
      entered.resolve(); await closing.promise;
    }
  });
  let close: Promise<void> | undefined;
  try {
    await client.startForFile(path, scope, "attach", "old");
    await client.notifyDocumentOpen(path, "old", "old");
    close = client.notifyDocumentClose(path, "old");
    await entered.promise;
    await client.startForFile(path, scope, "attach", "new");
    await client.notifyDocumentOpen(path, "new", "new");
    closing.resolve(); await close;
    expect(documents.get(path.toLowerCase())?.attachmentId).toBe("new");
    expect(documents.get(path.toLowerCase())?.content).toBe("new");
  } finally {
    closing.resolve(); await close;
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);

test("a manual restart completing an old close cannot detach or synchronize the reopened editor", async () => {
  const { client, documents, fileAttachmentIds } = clientFixture();
  const closing = deferred<void>();
  const entered = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const stopped: unknown[] = [];
  const feedback = spyOn(useLspStore.getState().actions, "clearLspError").mockImplementation(() => {});
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_document_close" && args.attachmentId === "old") {
      entered.resolve(); await closing.promise;
    }
    if (command === "lsp_stop_for_file") stopped.push(args.attachmentId);
  });
  let restart: Promise<void> | undefined;
  try {
    await client.startForFile(path, scope, "attach", "old");
    await client.notifyDocumentOpen(path, "old", "old");
    restart = client.restartForFile(path, scope, "obsolete restart text");
    await Promise.race([entered.promise, restart.then(() => {
      throw new Error("restart completed without reaching its owned document close");
    })]);
    await client.startForFile(path, scope, "attach", "new");
    await client.notifyDocumentOpen(path, "current editor text", "new");
    closing.resolve(); await restart;
    expect(stopped).toEqual(["old"]);
    expect(fileAttachmentIds.get(path.toLowerCase())).toBe("new");
    expect(documents.get(path.toLowerCase())?.content).toBe("current editor text");
  } finally {
    closing.resolve(); await restart;
    native.mockRestore(); resolver.mockRestore(); feedback.mockRestore();
  }
}, 2000);

test("a queued old editor change never synchronizes its text into a reopened attachment", async () => {
  const { client, documents } = clientFixture();
  const changing = deferred<void>();
  const entered = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const changes: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_document_change") {
      changes.push(args.content);
      if (args.attachmentId === "old") { entered.resolve(); await changing.promise; }
    }
  });
  const tasks: Promise<void>[] = [];
  try {
    await client.startForFile(path, scope, "attach", "old");
    await client.notifyDocumentOpen(path, "old text", "old");
    const first = client.synchronizeDocument(path, "first old change");
    tasks.push(first);
    await entered.promise;
    const queued = client.synchronizeDocument(path, "queued obsolete text");
    tasks.push(queued);
    await client.startForFile(path, scope, "attach", "new");
    await client.notifyDocumentOpen(path, "new buffer text", "new");
    changing.resolve(); await Promise.all(tasks);
    expect(changes).toEqual(["first old change"]);
    expect(documents.get(path.toLowerCase())?.content).toBe("new buffer text");
    await client.synchronizeDocument(path, "current edit", undefined, "new");
    expect(changes).toEqual(["first old change", "current edit"]);
    expect(documents.get(path.toLowerCase())?.content).toBe("current edit");
  } finally {
    changing.resolve(); await Promise.allSettled(tasks);
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);

test.each(["success", "failure"])("plugin replacement cancels a late native %s before React releases its editor", async (outcome) => {
  const { client, failedLanguageServers } = clientFixture();
  const gate = deferred<void>();
  const entered = deferred<void>();
  const resolver = spyOn(launchResolver, "resolveEditorLspLaunch").mockResolvedValue(launch);
  const stopped: unknown[] = [];
  const native = nativeSpy(async (command, args) => {
    if (command === "lsp_start_for_file") { entered.resolve(); await gate.promise; }
    if (command === "lsp_stop_for_file") stopped.push(args.attachmentId);
  });
  setPluginActive(launch.pluginId!, true);
  const starting = client.startForFile(path, scope, "attach", "revoked");
  try {
    await entered.promise;
    // Native revocation runs synchronously; React's cleanup is deliberately
    // not involved. The provider generation is already obsolete either way.
    setPluginActive(launch.pluginId!, false);
    setPluginActive(launch.pluginId!, true);
    if (outcome === "success") gate.resolve();
    else gate.reject(new Error("plugin was inactive while initializing"));
    expect(await starting).toEqual({ kind: "cancelled", reason: "superseded" });
    expect(failedLanguageServers.size).toBe(0);
    if (outcome === "success") expect(stopped).toEqual(["revoked"]);
  } finally {
    gate.resolve(); await Promise.allSettled([starting]);
    setPluginActive(launch.pluginId!, false);
    native.mockRestore(); resolver.mockRestore();
  }
}, 2000);
