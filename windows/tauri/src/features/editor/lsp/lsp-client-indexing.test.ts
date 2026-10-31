import { expect, spyOn, test } from "bun:test";
import * as indexing from "@/features/file-explorer/stores/workspace-indexing";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import * as adapter from "@/platform/lsp-core-adapter";
import { createPaneContent } from "@/features/editor/stores/buffer-content-factory";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { registerMountedLspDocument } from "./mounted-lsp-documents";
import { LspClient } from "./lsp-client";

test.each([
  ["C:/main/src/main.go", "C:/main", "src"],
  ["D:/added/src/main.go", "D:/added", "src"],
  ["d:\\ADDED\\nested\\SRC\\main.go", "D:/added/nested", "SRC"],
  ["//?/D:/added/main.go", "D:/added", "."],
  ["E:/outside/main.go", undefined, undefined],
] as const)("LSP indexing uses the file's owning root: %s", async (file, owner, parent) => {
  const workspaceId = "indexing-lsp-fixture";
  const scope = { workspaceId, root: "C:/main" };
  const store = useFileSystemStore.getStore(workspaceId);
  store.setState({
    rootFolderPath: scope.root,
    workspaceFolders: [
      { path: "D:/added", name: "added", isPrimary: false },
      { path: "D:/added/nested", name: "nested", isPrimary: false },
    ],
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({
    revision: 1,
    excludedDirectories: {},
    gitIgnoreFailed: false,
  });
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockReturnValue(null);
  const client = Object.create(LspClient.prototype) as LspClient;
  const starts: unknown[] = [];
  Object.assign(client, {
    fileAttachmentIds: new Map(),
    fileStartTasks: new Map(),
    startFileAttachment: async (_file: string, receivedScope: unknown) => {
      starts.push(receivedScope);
      return { kind: "attached", attachmentId: "fixture" };
    },
  });
  try {
    expect((await client.startForFile(file, scope)).kind).toBe("attached");
    expect(starts).toEqual([scope]);
    if (owner) expect(configure).toHaveBeenCalledWith(owner, [parent], false, workspaceId);
    else expect(configure).not.toHaveBeenCalled();
    if (owner) {
      configure.mockResolvedValue({
        revision: 2,
        excludedDirectories: { [parent!]: "manual" },
        gitIgnoreFailed: false,
      });
      expect(await client.startForFile(file, scope)).toEqual({
        kind: "cancelled",
        reason: "excluded",
      });
      expect(starts).toHaveLength(1);
      configure.mockImplementation(async () => {
        workspaceRuntimeRegistry.removeWorkspace(workspaceId);
        return { revision: 3, excludedDirectories: {}, gitIgnoreFailed: false };
      });
      expect(await client.startForFile(file, scope)).toEqual({
        kind: "cancelled",
        reason: "superseded",
      });
      expect(workspaceRuntimeRegistry.hasWorkspace(workspaceId)).toBe(false);
    }
  } finally {
    configure.mockRestore();
    snapshot.mockRestore();
    workspaceRuntimeRegistry.removeWorkspace(workspaceId);
  }
});


test.each([false, true])("background buffers restore LSP even when initial exclusion prevented startup: %s", async (serverRunning) => {
  const id = "background-lsp-indexing";
  const runtime = workspaceRuntimeRegistry.ensureWorkspace({id, name: id}, "ready");
  const files = useFileSystemStore.getStore(id);
  files.setState({rootFolderPath: "C:/background", workspaceFolders: []});
  const buffers = useBufferStore.getStore(id);
  const file = "C:/background/src/Main.java";
  buffers.setState({buffers: [createPaneContent("source", {type: "editor", path: file, name: "Main.java", content: "class Main {}"})]});
  const events: string[] = [];
  const attachments = new Map([[file.toLowerCase(), "existing"]]);
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {indexingRefreshTasks: new Map(), indexingRefreshVersions: new Map(),
    documentOpenTasks: new Map(), documentChangeTasks: new Map(), fileAttachmentIds: attachments,
    isWorkspaceActive: () => serverRunning,
    startForFile: async () => { events.push("attach"); return {kind: "attached", attachmentId: "existing"}; },
    notifyDocumentClose: async () => { events.push("close"); },
    notifyDocumentOpen: async () => { events.push("open"); },
    stopForFile: async () => { events.push("stop"); },
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({revision: 1, excludedDirectories: {src: "git"}, gitIgnoreFailed: false});
  try {
    const unmount = registerMountedLspDocument(runtime, file);
    try { await client.refreshIndexingDocuments("C:/background"); expect(events).toEqual([]); }
    finally { unmount(); }
    await client.refreshIndexingDocuments("C:/background");
    expect(events).toEqual(["close"]);
    configure.mockResolvedValue({revision: 1, excludedDirectories: {}, gitIgnoreFailed: false});
    await client.refreshIndexingDocuments("C:/background");
    expect(events).toEqual(["close", "close", "attach", "open"]);
    configure.mockImplementation(async () => {
      buffers.setState({buffers: []});
      return {revision: 1, excludedDirectories: {}, gitIgnoreFailed: false};
    });
    await client.refreshIndexingDocuments("C:/background");
    expect(events).toEqual(["close", "close", "attach", "open"]);
    expect(attachments.get(file.toLowerCase())).toBe("existing");
  } finally {
    configure.mockRestore(); await runtime.disposeIndexing?.(); workspaceRuntimeRegistry.removeWorkspace(id);
  }
});

test("unsupported buffers and a failed provider do not block later background documents", async () => {
  const id = "background-provider-isolation";
  const runtime = workspaceRuntimeRegistry.ensureWorkspace({id, name: id}, "ready");
  useFileSystemStore.getStore(id).setState({rootFolderPath: "C:/background", workspaceFolders: []});
  const buffers = useBufferStore.getStore(id);
  buffers.setState({buffers: ["README.txt", "Broken.java", "Main.java"].map((name) =>
    createPaneContent(name, {type: "editor", path: `C:/background/${name}`, name, content: name}),
  )});
  const opened: string[] = [];
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    indexingRefreshTasks: new Map(), indexingRefreshVersions: new Map(),
    documentOpenTasks: new Map(), documentChangeTasks: new Map(), fileAttachmentIds: new Map(),
    startForFile: async (path: string) => {
      if (path.endsWith("Broken.java")) throw new Error("provider unavailable");
      return {kind: "attached", attachmentId: "ready"};
    },
    notifyDocumentOpen: async (path: string) => { opened.push(path); },
    stopForFile: async () => {},
  });
  const configure = spyOn(indexing, "configureWorkspaceIndexing").mockResolvedValue({revision: 1, excludedDirectories: {}, gitIgnoreFailed: false});
  try {
    await client.refreshIndexingDocuments("C:/background");
    expect(configure).toHaveBeenCalledTimes(2);
    expect(opened).toEqual(["C:/background/Main.java"]);
  } finally {
    configure.mockRestore(); await runtime.disposeIndexing?.(); workspaceRuntimeRegistry.removeWorkspace(id);
  }
}, 1000);

test("reopening waits for close and a second opener synchronizes its newer text", async () => {
  const file = "C:/work/Main.java";
  const key = file.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, {phase: "open", attachmentId: "owner", content: "old", version: 1}]]);
  Object.assign(client, {documents, fileAttachmentIds: new Map([[key, "owner"]]),
    documentOpenTasks: new Map(), documentCloseTasks: new Map(), documentChangeTasks: new Map()});
  let finishClose!: () => void;
  const closing = new Promise<void>((resolve) => { finishClose = resolve; });
  let finishOpen!: () => void;
  const opening = new Promise<void>((resolve) => { finishOpen = resolve; });
  const events: string[] = [];
  const invoke = spyOn(adapter, "invokeLsp").mockImplementation(async (command, args) => {
    events.push(`${command}:${args?.content ?? ""}`);
    if (command === "lsp_document_close") await closing;
    if (command === "lsp_document_open") await opening;
    return undefined as never;
  });
  const close = client.notifyDocumentClose(file, "owner");
  const first = client.notifyDocumentOpen(file, "before", "owner");
  const second = client.notifyDocumentOpen(file, "newer", "owner");
  try {
    expect(events).toEqual(["lsp_document_close:"]);
    finishClose(); await close;
    finishOpen(); await Promise.all([first, second]);
    expect(events).toEqual(["lsp_document_close:", "lsp_document_open:before", "lsp_document_change:newer"]);
    expect(documents.get(key)?.content).toBe("newer");
  } finally {
    finishClose(); finishOpen(); await Promise.allSettled([close, first, second]); invoke.mockRestore();
  }
}, 1000);
