import { describe, expect, mock, test } from "bun:test";
import type { DocumentLifecycleDecision } from "@/platform/document-lifecycle";
import { handleExternalDocumentChange, resolveExternalDocumentConflict, type DocumentBufferOwner, type DocumentBufferSnapshot } from "./document-external-change-workflow";

function owner(status: "clean" | "dirty" | "saving" = "clean") {
  let snapshot: DocumentBufferSnapshot = {
    bufferId: "buffer-a", path: "C:/workspace/src/A.java", baseline: "baseline",
    lifecycle: status === "clean" ? { status, revision: 2 } : status === "dirty" ? { status, revision: 3, savedRevision: 2 } : { status, revision: 3, savedRevision: 2, saveRevision: 3, operationId: "save-a" },
  };
  let text = status === "clean" ? "baseline" : "editor text";
  const replaceWithDiskContent = mock((content: string) => { text = content; snapshot = { ...snapshot, baseline: content, lifecycle: { status: "clean", revision: snapshot.lifecycle.revision + 1 } }; });
  const value: DocumentBufferOwner = {
    getSnapshot: () => snapshot,
    applyLifecycle: (lifecycle) => { snapshot = { ...snapshot, lifecycle }; },
    replaceWithDiskContent,
    observeConflict: (content) => { snapshot = { ...snapshot, externalContent: content }; },
    acknowledgeDisk: (content) => { snapshot = { ...snapshot, baseline: content, externalContent: undefined }; },
  };
  return { value, replaceWithDiskContent, text: () => text, snapshot: () => snapshot };
}
const conflict = async (): Promise<DocumentLifecycleDecision> => ({ state: { status: "conflict", revision: 3, savedRevision: 2 }, action: "showConflict" });
const trace = () => {};

describe("external document change workflow", () => {
  test("preserves dirty editor text and records the actual disk version", async () => {
    const document = owner("dirty");
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { decide: conflict, readFile: async () => "external", trace } })).toBe("conflict");
    expect(document.text()).toBe("editor text");
    expect(document.snapshot().externalContent).toBe("external");
  });
  test("reloads a clean document from disk", async () => {
    const document = owner();
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { decide: async () => ({ state: { status: "clean", revision: 2 }, action: "reloadFromDisk" }), readFile: async () => "external", trace } })).toBe("reloaded");
    expect(document.text()).toBe("external");
  });
  test("does not turn a delayed self-save notification into a dirty-document conflict", async () => {
    const document = owner("dirty"); const decide = mock(conflict);
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { decide, readFile: async () => "baseline", trace } })).toBe("ignored");
    expect(decide).not.toHaveBeenCalled(); expect(document.text()).toBe("editor text");
  });
  test("skips decoding when the watcher sees the acknowledged raw bytes", async () => {
    const document = owner("dirty"); const decide = mock(conflict);
    const readChange = mock(async () => ({ status: "unchanged" as const }));
    const readDetails = mock(async () => { throw new Error("unchanged bytes must not be decoded"); });
    expect(await handleExternalDocumentChange({
      owner: document.value,
      operationId: "self-save",
      dependencies: { decide, readChange, readDetails, trace },
    })).toBe("ignored");
    expect(readChange).toHaveBeenCalledTimes(1);
    expect(readDetails).not.toHaveBeenCalled();
    expect(decide).not.toHaveBeenCalled();
  });
  test("missing clean file preserves text and requests the shared disk-conflict transition", async () => {
    const document = owner(); const decide = mock(async (..._args: unknown[]) => conflict());
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { decide, readFile: async () => null, trace } })).toBe("conflict");
    expect(decide.mock.calls[0]?.[1]).toEqual({ type: "diskConflict" });
    expect(document.text()).toBe("baseline"); expect(document.snapshot().externalContent).toBeNull();
  });
  test("defers notifications while a save owns the document", async () => {
    const document = owner("saving"); const readFile = mock(async () => "external");
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { readFile, trace } })).toBe("deferred");
    expect(readFile).not.toHaveBeenCalled();
  });
  test("an edit during the Core decision prevents a stale reload", async () => {
    const document = owner();
    const result = await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { trace, readFile: async () => "external", decide: async () => {
      document.value.applyLifecycle({ status: "dirty", revision: 3, savedRevision: 2 });
      return { state: { status: "clean", revision: 2 }, action: "reloadFromDisk" };
    } } });
    expect(result).toBe("deferred"); expect(document.replaceWithDiskContent).not.toHaveBeenCalled();
  });
  test("keep-editor acknowledges only the observed disk bytes and preserves editor text", async () => {
    const document = owner("dirty");
    await handleExternalDocumentChange({ owner: document.value, operationId: "watch", dependencies: { decide: conflict, readFile: async () => "external B", trace } });
    await resolveExternalDocumentConflict(document.value, "keepEditor", "choice", { decide: async () => ({ state: { status: "dirty", revision: 3, savedRevision: 2 }, action: "none" }), trace });
    expect(document.snapshot().baseline).toBe("external B"); expect(document.text()).toBe("editor text");
    expect(await handleExternalDocumentChange({ owner: document.value, operationId: "watch-2", dependencies: { decide: conflict, readFile: async () => "external C", trace } })).toBe("conflict");
  });
});

test("acknowledging a missing file survives duplicate notifications until recreation", async () => {
  const document = owner();
  await handleExternalDocumentChange({ owner: document.value, operationId: "missing", dependencies: { decide: conflict, readFile: async () => null, trace } });
  await resolveExternalDocumentConflict(document.value, "keepEditor", "recreate", { decide: async () => ({ state: { status: "dirty", revision: 3, savedRevision: 2 }, action: "none" }), trace });
  const decide = mock(conflict);
  expect(await handleExternalDocumentChange({ owner: document.value, operationId: "duplicate", dependencies: { decide, readFile: async () => null, trace } })).toBe("ignored");
  expect(decide).not.toHaveBeenCalled();
  expect(document.snapshot().baseline).toBeNull();
  expect(await handleExternalDocumentChange({ owner: document.value, operationId: "recreated-elsewhere", dependencies: { decide, readFile: async () => "external recreation", trace } })).toBe("conflict");
});
