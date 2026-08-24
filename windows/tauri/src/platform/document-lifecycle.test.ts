import { describe, expect, mock, test } from "bun:test";
import {
  applyLocalDocumentEdit,
  decideDocumentLifecycle,
  DocumentLifecycleCoreError,
} from "./document-lifecycle";

describe("document lifecycle core adapter", () => {
  test("keeps local edits in-process and preserves save ownership", () => {
    const saving = {
      status: "saving" as const,
      revision: 4,
      savedRevision: 2,
      saveRevision: 4,
      operationId: "save-1",
    };

    expect(applyLocalDocumentEdit(saving, 5, false)).toEqual({
      ...saving,
      revision: 5,
    });
  });

  test("sends persistence events through document.lifecycle with operationID", async () => {
    const executeCore = mock(async (_request: string) =>
      JSON.stringify({
        ok: true,
        data: {
          state: {
            status: "saving",
            revision: 3,
            savedRevision: 1,
            saveRevision: 3,
            operationId: "save-7",
          },
          action: "writeToDisk",
        },
      }),
    );

    await decideDocumentLifecycle(
      { status: "dirty", revision: 3, savedRevision: 1 },
      { type: "saveStarted", operationId: "save-7" },
      { executeCore },
    );

    const request = JSON.parse(executeCore.mock.calls[0][0]);
    expect(request.command).toBe("document.lifecycle");
    expect(request.operationId).toBe("save-7");
    expect(request.payload.event).toEqual({ type: "saveStarted", operationId: "save-7" });
  });

  test("fails closed when Core returns an invalid response", async () => {
    const executeCore = mock(async (_request: string) => "not-json");

    expect(
      decideDocumentLifecycle(
        { status: "dirty", revision: 2, savedRevision: 1 },
        { type: "externalChanged" },
        { executeCore },
      ),
    ).rejects.toThrow("invalid document lifecycle JSON");
  });

  test("preserves stable Core error codes for timeout and cancellation logging", async () => {
    const executeCore = mock(async (_request: string) =>
      JSON.stringify({
        ok: false,
        error: { code: "timed_out", message: "Operation timed out" },
      }),
    );

    try {
      await decideDocumentLifecycle(
        { status: "dirty", revision: 2, savedRevision: 1 },
        { type: "saveStarted", operationId: "save-timeout" },
        { executeCore },
      );
      throw new Error("Expected the Core request to fail");
    } catch (error) {
      expect(error).toBeInstanceOf(DocumentLifecycleCoreError);
      expect((error as DocumentLifecycleCoreError).code).toBe("timed_out");
    }
  });
});
