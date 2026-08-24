import { describe, expect, test } from "bun:test";
import type { DocumentLifecycleDecision } from "@/platform/document-lifecycle";
import {
  mergeGrantedDocumentSave,
  mergeTerminalDocumentSave,
  type DocumentSaveContext,
} from "./document-save-lifecycle";

const context: DocumentSaveContext = {
  bufferId: "buffer-a",
  path: "C:/workspace/A.java",
  operationId: "save-1",
};

describe("document save lifecycle response merging", () => {
  test("keeps edits made while Core grants save ownership", () => {
    const granted: DocumentLifecycleDecision = {
      state: {
        status: "saving",
        revision: 4,
        savedRevision: 2,
        saveRevision: 4,
        operationId: context.operationId,
      },
      action: "writeToDisk",
    };

    expect(
      mergeGrantedDocumentSave(granted, {
        status: "dirty",
        revision: 5,
        savedRevision: 2,
      }),
    ).toEqual({ ...granted.state, revision: 5 });
  });

  test("does not replace a conflict with a late save grant", () => {
    const granted: DocumentLifecycleDecision = {
      state: {
        status: "saving",
        revision: 4,
        savedRevision: 2,
        saveRevision: 4,
        operationId: context.operationId,
      },
      action: "writeToDisk",
    };

    expect(
      mergeGrantedDocumentSave(granted, {
        status: "conflict",
        revision: 4,
        savedRevision: 2,
      }),
    ).toBeNull();
  });

  test("keeps a newer edit dirty after the saved snapshot completes", () => {
    const completed: DocumentLifecycleDecision = {
      state: { status: "clean", revision: 4 },
      action: "none",
    };

    expect(
      mergeTerminalDocumentSave(
        completed,
        {
          status: "saving",
          revision: 5,
          savedRevision: 2,
          saveRevision: 4,
          operationId: context.operationId,
        },
        context,
        false,
      ),
    ).toEqual({ status: "dirty", revision: 5, savedRevision: 4 });
  });

  test("rejects a completion after another save owns the document", () => {
    const completed: DocumentLifecycleDecision = {
      state: { status: "clean", revision: 4 },
      action: "none",
    };

    expect(
      mergeTerminalDocumentSave(
        completed,
        {
          status: "saving",
          revision: 5,
          savedRevision: 2,
          saveRevision: 5,
          operationId: "save-2",
        },
        context,
        false,
      ),
    ).toBeNull();
  });
});
