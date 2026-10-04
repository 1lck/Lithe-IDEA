import { expect, spyOn, test } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

// Exercise physical and decompiled source ownership without starting native listeners.
test.each(["physical", "virtual"])("navigation cache follows the owning %s document session", (kind) => {
  const source = "C:/work/Main.java";
  const key = source.toLowerCase();
  const target = kind === "physical" ? { filePath: source } : {
    filePath: "C:/cache/String.java",
    sessionFilePath: source,
    documentUri: "jdt://contents/java.base/java.lang/String.class",
  };
  const client = Object.create(LspClient.prototype) as LspClient;
  const fileAttachmentIds = new Map([[key, "attachment-1"]]);
  const documents = new Map([[key, { phase: "open" }]]);
  Object.assign(client, { fileAttachmentIds, documents });
  let session: adapter.LspSessionSnapshot = {
    id: "java-session-1", workspacePath: "C:/work", languageId: "java",
    phase: "ready", operationId: "start-1",
    featureState: { phase: "known", features: ["definition"] },
  };
  const snapshot = spyOn(adapter, "getLspSessionSnapshot").mockImplementation((args) => {
    expect(args.sessionFilePath ?? args.filePath).toBe(source);
    return session;
  });
  try {
    const first = client.getDocumentNavigationContextKey(target);
    fileAttachmentIds.set("c:/work/other.java", "unrelated");
    expect(client.getDocumentNavigationContextKey(target)).toBe(first);
    fileAttachmentIds.set(key, "attachment-2");
    const reattached = client.getDocumentNavigationContextKey(target);
    expect(reattached).not.toBe(first);
    session = { ...session, id: "java-session-2" };
    const restarted = client.getDocumentNavigationContextKey(target);
    expect(restarted).not.toBe(reattached);
    session = { ...session, phase: "failed" };
    expect(client.getDocumentNavigationContextKey(target)).not.toBe(restarted);
    session = { ...session, phase: "ready" };
    documents.set(key, { phase: "closed" });
    expect(client.getDocumentNavigationContextKey(target)).not.toBe(restarted);
  } finally {
    snapshot.mockRestore();
  }
});
