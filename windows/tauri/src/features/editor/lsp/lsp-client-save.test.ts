import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";
import { registerLspDocumentChangeFlusher } from "./pending-document-changes";

test.each([false, true])("save waits for preceding edits and rejects reattachment=%s", async (reattach) => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, { phase: "open", attachmentId: "first" }]]);
  const fileAttachmentIds = new Map([[key, "first"]]);
  let release!: () => void;
  const previousChange = new Promise<void>((resolve) => { release = resolve; });
  Object.assign(client, { documents, fileAttachmentIds, documentOpenTasks: new Map(), documentChangeTasks: new Map([[key, previousChange]]) });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const save = client.notifyDocumentSave(filePath, "saved");
  try {
    await Promise.resolve(); await Promise.resolve();
    expect(invoke).not.toHaveBeenCalled();
    if (reattach) {
      fileAttachmentIds.set(key, "second");
      documents.set(key, { phase: "open", attachmentId: "second" });
    }
    release();
    await save;
    if (reattach) expect(invoke).not.toHaveBeenCalled();
    else expect(invoke).toHaveBeenCalledWith("lsp_document_save", { filePath, content: "saved", attachmentId: "first" });
  } finally {
    release();
    await save;
    invoke.mockRestore();
  }
}, 1000);

test.each([false, true])("save awaits mounted restoration before capturing an attachment, failure=%s", async (failed) => {
  const filePath = "C:/restore/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const attachments = new Map<string, string>();
  const documents = new Map();
  Object.assign(client, {fileAttachmentIds: attachments, documents, documentOpenTasks: new Map(),
    documentChangeTasks: new Map(), documentCloseTasks: new Map(), documentSaveTasks: new Map()});
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const unregister = registerLspDocumentChangeFlusher(filePath, async () => {
    await gate;
    if (failed) throw new Error("restoration failed");
    attachments.set(key, "restored");
    documents.set(key, {phase: "open", attachmentId: "restored", content: "saved", version: 1});
  });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  let settled = false;
  const saving = client.notifyDocumentSave(filePath, "saved");
  const observed = saving.then(() => { settled = true; }, () => { settled = true; });
  try {
    await Promise.resolve(); await Promise.resolve();
    expect(settled).toBe(false);
    release();
    if (failed) await expect(saving).rejects.toThrow("restoration failed");
    else {
      await saving;
      expect(invoke).toHaveBeenCalledWith("lsp_document_save", {filePath, content: "saved", attachmentId: "restored"});
    }
  } finally {
    release(); await observed; unregister(); invoke.mockRestore();
  }
}, 1000);

test("queued save synchronization never writes an old buffer into a replacement attachment", async () => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, { phase: "open", attachmentId: "first", content: "old", version: 1 }]]);
  const fileAttachmentIds = new Map([[key, "first"]]);
  let release!: () => void;
  const prior = new Promise<void>((resolve) => { release = resolve; });
  Object.assign(client, { documents, fileAttachmentIds, documentOpenTasks: new Map(), documentChangeTasks: new Map([[key, prior]]) });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const save = client.notifyDocumentSave(filePath, "saved", "current");
  try {
    await Promise.resolve(); await Promise.resolve();
    fileAttachmentIds.set(key, "replacement");
    documents.set(key, { phase: "open", attachmentId: "replacement", content: "replacement contents", version: 1 });
    release();
    await save;
    expect(invoke).not.toHaveBeenCalled();
    expect(documents.get(key)?.content).toBe("replacement contents");
  } finally {
    release(); await save; invoke.mockRestore();
  }
}, 1000);

test.each([false, true])("save follows its mounted restoration but rejects a different editor owner=%s", async (replacedOwner) => {
  const filePath = "C:/restored/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const attachments = new Map([[key, "borrowed-before-remount"]]);
  const documents = new Map([[key, {phase: "open", attachmentId: "borrowed-before-remount", content: "old", version: 1}]]);
  Object.assign(client, {fileAttachmentIds: attachments, documents, documentOpenTasks: new Map(),
    documentChangeTasks: new Map(), documentCloseTasks: new Map(), documentSaveTasks: new Map()});
  let release!: () => void;
  const ready = new Promise<void>((resolve) => { release = resolve; });
  const mountedOwner = {};
  const unregister = registerLspDocumentChangeFlusher(filePath, async () => {
    await ready;
    if (!replacedOwner) {
      attachments.set(key, "restored");
      documents.set(key, {phase: "open", attachmentId: "restored", content: "saved", version: 1});
    }
  }, mountedOwner);
  let unregisterReplacement = () => {};
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const synchronize = spyOn(client, "synchronizeDocument").mockResolvedValue(undefined);
  const saving = client.notifyDocumentSave(filePath, "saved", "saved");
  try {
    if (replacedOwner) {
      unregisterReplacement = registerLspDocumentChangeFlusher(filePath, async () => {
        attachments.set(key, "replacement");
        documents.set(key, {phase: "open", attachmentId: "replacement", content: "replacement text", version: 1});
      }, {});
    }
    release(); await saving;
    if (replacedOwner) {
      expect(invoke).not.toHaveBeenCalled();
      expect(synchronize).not.toHaveBeenCalled();
      expect(documents.get(key)?.content).toBe("replacement text");
    } else {
      expect(invoke).toHaveBeenCalledWith("lsp_document_save", {filePath, content: "saved", attachmentId: "restored"});
      expect(synchronize).toHaveBeenCalledWith(filePath, "saved", [], "restored");
    }
  } finally {
    release(); await saving; unregister(); unregisterReplacement(); invoke.mockRestore(); synchronize.mockRestore();
  }
}, 1000);

test("save synchronizes newer editor text before reporting the older disk snapshot", async () => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    documentOpenTasks: new Map(), documents: new Map([[key, { phase: "open", attachmentId: "first", content: "older", version: 1 }]]),
    fileAttachmentIds: new Map([[key, "first"]]), documentChangeTasks: new Map(),
  });
  const events: string[] = [];
  const change = spyOn(client, "synchronizeDocument").mockImplementation(async (_path, text) => { events.push(`change:${text}`); });
  const invoke = spyOn(adapter, "invokeLsp").mockImplementation(async (command, args) => {
    events.push(`${command}:${args?.content}`);
    return undefined as never;
  });
  try {
    await client.notifyDocumentSave(filePath, "saved", "newer unsaved");
    expect(events).toEqual(["change:newer unsaved", "lsp_document_save:saved"]);
  } finally {
    change.mockRestore(); invoke.mockRestore();
  }
});


test.each(["ready", "replaced", "failed"] as const)("save drains only its captured document open: %s", async (outcome) => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map<string, {phase: "open"; attachmentId: string}>();
  const fileAttachmentIds = new Map([[key, "restored"]]);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const opening = gate.then(() => {
    if (outcome === "failed") throw new Error("document open failed");
    documents.set(key, {phase: "open", attachmentId: "restored"});
  });
  Object.assign(client, {documents, fileAttachmentIds, documentChangeTasks: new Map(),
    documentOpenTasks: new Map([[key, {attachmentId: "restored", task: opening}]]),
  });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const synchronize = spyOn(client, "synchronizeDocument").mockResolvedValue(undefined);
  let settled = false;
  const openingObserved = opening.catch(() => undefined);
  const saving = client.notifyDocumentSave(filePath, "saved");
  const observed = saving.then(() => { settled = true; }, () => { settled = true; });
  try {
    // Drain the old implementation's single queue await and completion callback.
    await Promise.resolve();
    await Promise.resolve();
    expect(settled).toBe(false);
    expect(invoke).not.toHaveBeenCalled();
    expect(synchronize).not.toHaveBeenCalled();
    if (outcome === "replaced") fileAttachmentIds.set(key, "replacement");
    release();
    if (outcome === "failed") await expect(saving).rejects.toThrow("document open failed");
    else await saving;
    if (outcome === "ready") {
      expect(synchronize).not.toHaveBeenCalled();
      expect(invoke).toHaveBeenCalledWith("lsp_document_save", {filePath, content: "saved", attachmentId: "restored"});
    } else {
      expect(synchronize).not.toHaveBeenCalled();
      expect(invoke).not.toHaveBeenCalled();
    }
  } finally {
    release();
    await observed;
    await openingObserved;
    invoke.mockRestore(); synchronize.mockRestore();
  }
}, 1000);

test.each([false, true])("close drains its exact in-flight save, including failure=%s", async (failSave) => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  let release!: () => void;
  const precedingChange = new Promise<void>((resolve) => { release = resolve; });
  Object.assign(client, {
    fileAttachmentIds: new Map([[key, "restored"]]),
    documents: new Map([[key, {filePath, phase: "open", attachmentId: "restored", content: "saved", version: 1}]]),
    documentOpenTasks: new Map(), documentSaveTasks: new Map(), documentCloseTasks: new Map(),
    documentChangeTasks: new Map([[key, precedingChange]]),
  });
  const events: string[] = [];
  const invoke = spyOn(adapter, "invokeLsp").mockImplementation(async <T>(command: string): Promise<T> => {
    events.push(command);
    if (command === "lsp_document_save" && failSave) throw new Error("save notification failed");
    return undefined as T;
  });
  let entered!: () => void;
  const synchronizing = new Promise<void>((resolve) => { entered = resolve; });
  const synchronize = spyOn(client, "synchronizeDocument").mockImplementation(async () => {
    entered(); await precedingChange;
  });
  const saving = client.notifyDocumentSave(filePath, "saved", "saved");
  const saved = saving.then(() => "saved", (error: Error) => error.message);
  await synchronizing;
  const closing = client.notifyDocumentClose(filePath, "restored");
  const duplicateClose = client.notifyDocumentClose(filePath, "restored");
  try {
    await Promise.resolve(); await Promise.resolve();
    expect(events).toEqual([]);
    release();
    expect(await saved).toBe(failSave ? "save notification failed" : "saved");
    await closing;
    await duplicateClose;
    expect(events).toEqual(["lsp_document_save", "lsp_document_close"]);
  } finally {
    release();
    await Promise.allSettled([saving, closing, duplicateClose]);
    invoke.mockRestore(); synchronize.mockRestore();
  }
}, 1000);
