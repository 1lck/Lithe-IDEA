import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import type { EditorTextChange } from "../types/editor.types";
import { LspClient } from "./lsp-client";

const filePath = "C:/work/Main.java";
const key = filePath.toLowerCase();
const insert = (column: number, text: string): EditorTextChange => ({
  rangeOffset: column, rangeLength: 0, text,
  startLine: 0, startColumn: column, endLine: 0, endColumn: column,
});

function clientWith(content: string) {
  const client = Object.create(LspClient.prototype) as LspClient;
  const documents = new Map([[key, { phase: "open", attachmentId: "first", content, version: 1 }]]);
  Object.assign(client, {
    documents, fileAttachmentIds: new Map([[key, "first"]]), documentChangeTasks: new Map(),
  });
  return { client, documents };
}

test("ranges that lead to the editor's text are sent without the document", async () => {
  const { client, documents } = clientWith("abcd");
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  try {
    const changes = [insert(2, "X"), insert(3, "Y")];
    await client.synchronizeDocument(filePath, "abXYcd", changes);
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledWith("lsp_document_change", {
      filePath, version: 2, contentChanges: changes, attachmentId: "first",
    });
    expect(documents.get(key)).toMatchObject({ content: "abXYcd", version: 2 });
  } finally {
    invoke.mockRestore();
  }
}, 1000);

test("ranges already covered by an earlier full sync are not replayed on top of it", async () => {
  const { client } = clientWith("abXcd");
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue(undefined);
  try {
    await client.synchronizeDocument(filePath, "abXYcd", [insert(2, "X"), insert(3, "Y")]);
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledWith("lsp_document_change", {
      filePath, content: "abXYcd", version: 2, attachmentId: "first",
    });
  } finally {
    invoke.mockRestore();
  }
}, 1000);

test("a rejected ranged change is retried with the full text", async () => {
  const { client, documents } = clientWith("ab");
  const invoke = spyOn(adapter, "invokeLsp")
    .mockRejectedValueOnce(new Error("documentNotSynchronized"))
    .mockResolvedValue(undefined);
  try {
    await client.synchronizeDocument(filePath, "abX", [insert(2, "X")]);
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(invoke).toHaveBeenLastCalledWith("lsp_document_change", {
      filePath, content: "abX", version: 2, attachmentId: "first",
    });
    expect(documents.get(key)).toMatchObject({ content: "abX", version: 2 });
  } finally {
    invoke.mockRestore();
  }
}, 1000);
