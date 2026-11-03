import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

test.each([false, true])("save waits for preceding edits and rejects reattachment=%s", async (reattach) => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, { phase: "open", attachmentId: "first" }]]);
  const fileAttachmentIds = new Map([[key, "first"]]);
  let release!: () => void;
  const previousChange = new Promise<void>((resolve) => { release = resolve; });
  Object.assign(client, { documents, fileAttachmentIds, documentChangeTasks: new Map([[key, previousChange]]) });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const save = client.notifyDocumentSave(filePath, "saved");
  try {
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

test("queued save synchronization never writes an old buffer into a replacement attachment", async () => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, { phase: "open", attachmentId: "first", content: "old", version: 1 }]]);
  const fileAttachmentIds = new Map([[key, "first"]]);
  let release!: () => void;
  const prior = new Promise<void>((resolve) => { release = resolve; });
  Object.assign(client, { documents, fileAttachmentIds, documentChangeTasks: new Map([[key, prior]]) });
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  const save = client.notifyDocumentSave(filePath, "saved", "current");
  try {
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

test("save synchronizes newer editor text before reporting the older disk snapshot", async () => {
  const filePath = "C:/work/Main.java";
  const key = filePath.toLowerCase();
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    documents: new Map([[key, { phase: "open", attachmentId: "first", content: "older", version: 1 }]]),
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
