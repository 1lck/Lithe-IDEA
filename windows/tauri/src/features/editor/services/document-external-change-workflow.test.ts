import { describe, expect, mock, test } from "bun:test";
import type { DocumentLifecycleDecision } from "@/platform/document-lifecycle";
import {
  handleExternalDocumentChange,
  type DocumentBufferOwner,
  type DocumentBufferSnapshot,
} from "./document-external-change-workflow";

function owner(initial: DocumentBufferSnapshot) {
  let snapshot = initial;
  const replaceWithDiskContent = mock((content: string) => {
    snapshot = {
      ...snapshot,
      lifecycle: { status: "clean", revision: snapshot.lifecycle.revision + 1 },
    };
    void content;
  });
  const applyLifecycle = mock((lifecycle: DocumentBufferSnapshot["lifecycle"]) => {
    snapshot = { ...snapshot, lifecycle };
  });
  const value: DocumentBufferOwner = {
    getSnapshot: () => snapshot,
    applyLifecycle,
    replaceWithDiskContent,
  };
  return { value, applyLifecycle, replaceWithDiskContent };
}

describe("external document change workflow", () => {
  test("preserves dirty editor text and enters conflict without reading disk", async () => {
    const documentOwner = owner({
      bufferId: "buffer-a",
      path: "C:/workspace/A.java",
      lifecycle: { status: "dirty", revision: 3, savedRevision: 1 },
    });
    const readFile = mock(async () => "disk text");
    const decide = mock(async (): Promise<DocumentLifecycleDecision> => ({
      state: { status: "conflict", revision: 3, savedRevision: 1 },
      action: "showConflict",
    }));

    const result = await handleExternalDocumentChange({
      owner: documentOwner.value,
      operationId: "watch-1",
      dependencies: { decide, readFile, trace: () => {} },
    });

    expect(result).toBe("conflict");
    expect(readFile).not.toHaveBeenCalled();
    expect(documentOwner.replaceWithDiskContent).not.toHaveBeenCalled();
    expect(documentOwner.applyLifecycle).toHaveBeenCalledWith({
      status: "conflict",
      revision: 3,
      savedRevision: 1,
    });
  });

  test("reloads a clean document from disk", async () => {
    const documentOwner = owner({
      bufferId: "buffer-a",
      path: "C:/workspace/A.java",
      lifecycle: { status: "clean", revision: 2 },
    });

    const result = await handleExternalDocumentChange({
      owner: documentOwner.value,
      operationId: "watch-2",
      dependencies: {
        decide: async () => ({
          state: { status: "clean", revision: 2 },
          action: "reloadFromDisk",
        }),
        readFile: async () => "disk text",
        trace: () => {},
      },
    });

    expect(result).toBe("reloaded");
    expect(documentOwner.replaceWithDiskContent).toHaveBeenCalledWith("disk text");
  });
});
