import { expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import * as deferred from "@/features/editor/lsp/deferred-lsp-work";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as adapter from "@/platform/lsp-core-adapter";
import { installHappyDom } from "@/test-utils/happy-dom";
import { flushLspDocumentChanges, queueLspDocumentChanges, takeLspDocumentChanges } from "@/features/editor/lsp/pending-document-changes";
import { useLspIntegration } from "./use-lsp-integration";
import { invalidateDeclarativeLanguageSupport } from "@/features/editor/lsp/declarative-language-support";

test("adding and removing a nested root reevaluates an open document's LSP policy", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const workspaceId = "lsp-root-membership-fixture";
  const filePath = "C:/main/nested/src/Main.java";
  workspaceRuntimeRegistry.activateWorkspace({ id: workspaceId, name: "fixture" }, "ready");
  const store = useFileSystemStore.getStore(workspaceId);
  store.setState({ rootFolderPath: "C:/main", workspaceFolders: [] });
  const buffers = useBufferStore.getStore(workspaceId);
  buffers.setState({
    buffers: [
      createPaneContent("fixture", {
        type: "editor",
        name: "Main.java",
        path: filePath,
        content: "class Main {}",
      }),
    ],
  });
  const scheduled = new Set<() => void>();
  const defer = spyOn(deferred, "deferUntilAfterNextPaint").mockImplementation((work) => {
    scheduled.add(work);
    return () => {
      scheduled.delete(work);
    };
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockImplementation(
    async (root): Promise<indexing.IndexingStatus> => ({
      revision: 1,
      excludedDirectories: root.endsWith("nested") ? { src: "manual" } : {},
      gitIgnoreFailed: false,
    }),
  );
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  const events: string[] = [];
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    fileAttachmentIds: new Map(),
    fileStartTasks: new Map(),
    startFileAttachment: async () => ({ kind: "attached", attachmentId: "fixture" }),
    notifyDocumentOpen: async () => {
      events.push("open");
    },
    notifyDocumentClose: async () => {
      events.push("close");
    },
    stopForFile: async () => {
      events.push("stop");
    },
  });
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const host = document.createElement("div");
  const root = createRoot(host);
  function Probe() {
    useLspIntegration({ filePath });
    return null;
  }
  const flush = async () =>
    act(async () => {
      const ready = [...scheduled];
      scheduled.clear();
      for (const work of ready) work();
    });
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    await act(async () => root.render(<Probe />));
    await flush();
    expect(events).toEqual(["open"]);
    await act(async () =>
      store.setState({
        workspaceFolders: [{ path: "C:/main/nested", name: "nested", isPrimary: false }],
      }),
    );
    await flush();
    expect(events).toEqual(["open", "close", "stop"]);
    expect(configure).toHaveBeenLastCalledWith("C:/main/nested", ["src"], false, workspaceId);
    await act(async () => store.setState({ workspaceFolders: [] }));
    await flush();
    expect(events).toEqual(["open", "close", "stop", "open"]);
  } finally {
    buffers.setState({ buffers: [] });
    try {
      await act(async () => root.unmount());
    } finally {
      scheduled.clear();
      defer.mockRestore();
      configure.mockRestore();
      snapshot.mockRestore();
      instance.mockRestore();
      host.remove();
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      workspaceRuntimeRegistry.activateWorkspace({ id: previousWorkspace, name: "restored" });
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      restoreDom();
    }
  }
});


test.each([false, true])("native refresh restores mounted ownership through opening edits, synchronization failure=%s", async (failFirstSync) => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & {IS_REACT_ACT_ENVIRONMENT?: boolean};
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const workspaceId = "native-indexing-owner"; const filePath = "C:/native/src/Main.java";
  workspaceRuntimeRegistry.activateWorkspace({id: workspaceId, name: workspaceId}, "ready");
  useFileSystemStore.getStore(workspaceId).setState({rootFolderPath: "C:/native", workspaceFolders: []});
  const buffers = useBufferStore.getStore(workspaceId);
  const buffer = createPaneContent("native-source", {type: "editor", name: "Main.java", path: filePath, content: "before"});
  if (buffer.type !== "editor") throw new Error("Expected source editor fixture");
  buffers.setState({buffers: [buffer]});
  const scheduled = new Set<() => void>();
  const defer = spyOn(deferred, "deferUntilAfterNextPaint").mockImplementation((work) => { scheduled.add(work); return () => { scheduled.delete(work); }; });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({revision: 1, excludedDirectories: {src: "git"}, gitIgnoreFailed: false});
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  let didBeginOpening = false;
  let finish!: () => void; const opening = new Promise<void>((resolve) => { finish = resolve; });
  const synchronized: string[] = [];
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {fileAttachmentIds: new Map(), fileStartTasks: new Map(),
    startFileAttachment: async () => ({kind: "attached", attachmentId: "native-owner"}),
    notifyDocumentOpen: async () => { didBeginOpening = true; await opening; },
    notifyDocumentClose: async () => {}, stopForFile: async () => {},
    synchronizeDocument: async (_path: string, content: string) => {
      synchronized.push(content);
      if (failFirstSync && synchronized.length === 1) throw new Error("temporary sync failure");
    },
  });
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const host = document.createElement("div"); const renderer = createRoot(host);
  function Probe() { useLspIntegration({filePath}); return null; }
  const flush = () => act(async () => { const work = [...scheduled]; scheduled.clear(); for (const start of work) start(); });
  let pendingFlush: Promise<void> | undefined;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => renderer.render(<Probe />)); await flush();
    expect(synchronized).toEqual([]);
    configure.mockResolvedValue({revision: 1, excludedDirectories: {}, gitIgnoreFailed: false});
    await act(async () => window.dispatchEvent(new window.CustomEvent(indexing.indexingRefreshedEvent, {detail: "C:/native"})));
    expect(didBeginOpening).toBe(false);
    let flushFinished = false;
    // An explicit save must start deferred restoration without waiting for
    // another paint, then await the same owner's open gate.
    await act(async () => {
      pendingFlush = flushLspDocumentChanges(filePath).then(() => { flushFinished = true; });
    });
    expect(didBeginOpening).toBe(true);
    buffers.setState({buffers: [{...buffer, content: "edited-during-open"}]});
    expect(flushFinished).toBe(false);
    finish(); await act(async () => { await opening; await pendingFlush; });
    expect(flushFinished).toBe(true);
    expect(synchronized).toContain("edited-during-open");
    buffers.setState({buffers: [{...buffer, content: "edited-after-open"}]});
    queueLspDocumentChanges(filePath, [{rangeOffset: 0, rangeLength: "edited-during-open".length, text: "edited-after-open"}]);
    await flushLspDocumentChanges(filePath);
    expect(synchronized[synchronized.length - 1]).toBe("edited-after-open");
  } finally {
    finish(); await pendingFlush; buffers.setState({buffers: []}); await act(async () => renderer.unmount());
    scheduled.clear(); takeLspDocumentChanges(filePath);
    defer.mockRestore(); configure.mockRestore(); snapshot.mockRestore(); instance.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
    workspaceRuntimeRegistry.activateWorkspace({id: previousWorkspace, name: "restored"});
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct; restoreDom();
  }
}, 2000);

test.each(["failed", "pending", "open"] as const)("admitted model retries a %s Java import while retaining an open attachment", async (phase) => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const workspaceId = `lsp-model-retry-${phase}`;
  const filePath = "C:/model-retry/src/Main.java";
  workspaceRuntimeRegistry.activateWorkspace({ id: workspaceId, name: "fixture" }, "ready");
  useFileSystemStore.getStore(workspaceId).setState({ rootFolderPath: "C:/model-retry", workspaceFolders: [] });
  const buffers = useBufferStore.getStore(workspaceId);
  buffers.setState({ buffers: [createPaneContent("retry-source", { type: "editor", name: "Main.java", path: filePath, content: "class Main {}" })] });
  const scheduled = new Set<() => void>();
  const defer = spyOn(deferred, "deferUntilAfterNextPaint").mockImplementation((work) => {
    scheduled.add(work); return () => { scheduled.delete(work); };
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({ revision: 1, excludedDirectories: {}, gitIgnoreFailed: false });
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const starts: string[] = [];
  const opened: string[] = [];
  const stopped: string[] = [];
  const client = {
    startForFile: async (_path: string, _scope: unknown, _kind: unknown, attachmentId: string) => {
      starts.push(attachmentId);
      if (starts.length === 1) {
        if (phase === "failed") throw new Error("plugin.build.modelReloadRequired");
        if (phase === "pending") await gate;
      }
      return { kind: "attached", attachmentId };
    },
    notifyDocumentOpen: async (_path: string, _text: string, attachmentId: string) => { opened.push(attachmentId); },
    notifyDocumentClose: async () => {},
    stopForFile: async (_path: string, attachmentId: string) => { stopped.push(attachmentId); },
  } as unknown as LspClient;
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const host = document.createElement("div");
  const renderer = createRoot(host);
  function Probe() { useLspIntegration({ filePath }); return null; }
  const flush = () => act(async () => {
    const ready = [...scheduled]; scheduled.clear(); for (const work of ready) work();
  });
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => renderer.render(<Probe />)); await flush();
    expect(starts).toHaveLength(1);
    expect(opened).toHaveLength(phase === "open" ? 1 : 0);
    await act(async () => invalidateDeclarativeLanguageSupport()); await flush();
    expect(starts).toHaveLength(phase === "open" ? 1 : 2);
    release(); await act(async () => { await gate; });
    expect(opened).toEqual([starts[phase === "open" ? 0 : 1]!]);
    if (phase === "pending") expect(stopped).toContain(starts[0]!);
  } finally {
    release(); buffers.setState({ buffers: [] });
    await act(async () => { await gate; renderer.unmount(); });
    scheduled.clear(); instance.mockRestore(); configure.mockRestore(); defer.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
    workspaceRuntimeRegistry.activateWorkspace({ id: previousWorkspace, name: "restored" });
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    host.remove(); restoreDom();
  }
});

test.each([1, 3])("an explicit flush drains replacement initialization with bounded ownership changes=%s", async (replacementCount) => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const previousWorkspace = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const workspaceId = "lsp-replaced-initialization";
  const filePath = "C:/replaced-initialization/Main.java";
  workspaceRuntimeRegistry.activateWorkspace({ id: workspaceId, name: "fixture" }, "ready");
  useFileSystemStore.getStore(workspaceId).setState({ rootFolderPath: "C:/replaced-initialization", workspaceFolders: [] });
  const buffers = useBufferStore.getStore(workspaceId);
  buffers.setState({ buffers: [createPaneContent("source", { type: "editor", name: "Main.java", path: filePath, content: "class Main {}" })] });
  const scheduled = new Set<() => void>();
  const defer = spyOn(deferred, "deferUntilAfterNextPaint").mockImplementation((work) => {
    scheduled.add(work); return () => { scheduled.delete(work); };
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({ revision: 1, excludedDirectories: {}, gitIgnoreFailed: false });
  const gates = Array.from({ length: replacementCount + 1 }, () => Promise.withResolvers<void>());
  const closed = Array.from({ length: replacementCount }, () => Promise.withResolvers<void>());
  const starts: string[] = [];
  const opened: string[] = [];
  const client = {
    startForFile: async (_path: string, _scope: unknown, _kind: unknown, attachmentId: string) => {
      starts.push(attachmentId);
      await gates[starts.length - 1]!.promise;
      return { kind: "attached", attachmentId };
    },
    notifyDocumentOpen: async (_path: string, _text: string, attachmentId: string) => { opened.push(attachmentId); },
    notifyDocumentClose: async (_path: string, attachmentId: string) => {
      closed[starts.indexOf(attachmentId)]?.resolve();
    },
    stopForFile: async () => {},
  } as unknown as LspClient;
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const host = document.createElement("div");
  const renderer = createRoot(host);
  function Probe() { useLspIntegration({ filePath }); return null; }
  const flushScheduled = () => act(async () => {
    const work = [...scheduled]; scheduled.clear(); for (const start of work) start();
  });
  let pendingFlush: Promise<void> | undefined;
  let flushFinished = false;
  let flushError: unknown;
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    await act(async () => renderer.render(<Probe />)); await flushScheduled();
    expect(starts).toHaveLength(1);
    await act(async () => {
      pendingFlush = flushLspDocumentChanges(filePath).then(
        () => { flushFinished = true; }, (error: unknown) => { flushError = error; },
      );
    });
    // The callback registration and mounted buffer stay unchanged. Only its
    // pending attachment is replaced while the explicit flush awaits it.
    for (let index = 0; index < replacementCount; index += 1) {
      await act(async () => invalidateDeclarativeLanguageSupport()); await flushScheduled();
      expect(starts).toHaveLength(index + 2);
      gates[index]!.resolve();
      await act(async () => { await closed[index]!.promise; });
      expect(flushFinished).toBe(false);
      expect(opened).toEqual([]);
    }
    if (replacementCount === 3) {
      await pendingFlush;
      expect(flushError).toBeInstanceOf(Error);
      expect((flushError as Error).message).toContain("attachment changed repeatedly");
      return;
    }
    expect(flushError).toBeUndefined();
    gates[replacementCount]!.resolve();
    await act(async () => { await pendingFlush; });
    expect(flushFinished).toBe(true);
    expect(opened).toEqual([starts[1]!]);
  } finally {
    for (const gate of gates) gate.resolve();
    await pendingFlush;
    buffers.setState({ buffers: [] }); await act(async () => renderer.unmount());
    scheduled.clear(); takeLspDocumentChanges(filePath);
    instance.mockRestore(); configure.mockRestore(); defer.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
    workspaceRuntimeRegistry.activateWorkspace({ id: previousWorkspace, name: "restored" });
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    host.remove(); restoreDom();
  }
}, 2000);
