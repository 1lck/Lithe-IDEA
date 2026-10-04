import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import type * as Monaco from "monaco-editor";
import { installHappyDom } from "@/test-utils/happy-dom";

// `definition-link` only uses `editor.MouseTargetType` and `Range` from the
// full Monaco bundle, which otherwise reads many browser globals at module
// scope. Stub the module so this unit test exercises the gesture wiring alone.
mock.module("monaco-editor", () => ({
  editor: { MouseTargetType: { CONTENT_TEXT: 6 } },
  Range: class {
    constructor(
      public startLineNumber: number,
      public startColumn: number,
      public endLineNumber: number,
      public endColumn: number,
    ) {}
  },
}));

// The LSP client and frontend trace transitively import the Tauri API, which
// reads `window.__TAURI_INTERNALS__` at module scope. Deferred promises let
// the async-interleaving regression test control when the LSP response lands.
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => { resolve = next; });
  return { promise, resolve };
}

// The `resolve` function inside `registerMonacoDefinitionLinkGesture` calls
// `lspClient.getDefinition`. Stub it to return a controllable promise so the
// async-interleaving regression test can hold the response and observe the
// surface-deactivation check.
let available = true;
let preparationFailure: Error | null = null;
let definitionCalls = 0;
let navigationContext = "java:ready:attachment-1";
let navigationContextReads = 0;
let getDefinitionDeferred: { promise: Promise<unknown>; resolve: (value: unknown) => void } | null = null;
mock.module("@/features/editor/lsp/lsp-client", () => ({
  isDocumentFeatureAvailable: () => available,
  LspClient: {
    getInstance: () => ({
      getDocumentNavigationContextKey: () => { navigationContextReads += 1; return navigationContext; },
      getDocumentAvailability: () => ({ phase: available ? "ready" : "preparing", feature: "supported" }),
      ensureDocumentReady: async () => {
        if (preparationFailure) throw preparationFailure;
      },
      getDefinition: () => {
        definitionCalls += 1;
        getDefinitionDeferred = deferred<unknown>();
        return getDefinitionDeferred.promise;
      },
    }),
  },
}));
mock.module("@/features/editor/lsp/lombok-accessor-navigation", () => ({
  resolveLombokAccessorDefinition: async () => null,
}));
mock.module("@/utils/frontend-trace", () => ({
  frontendTrace: () => undefined,
}));
// `isEditorLspTargetSupported` keeps its real implementation: a `.java` path is
// recognized by a pure string check, while this stub keeps any other path
// unsupported and deterministic.
mock.module("@/extensions/registry/extension-registry", () => ({
  extensionRegistry: {
    isLspSupported: () => false,
    getLanguageId: () => undefined,
  },
}));

// `definition-link` still reads `window` while registering its listeners, so
// install a DOM realm before importing it dynamically (a static import would
// hoist ahead of `installHappyDom()`).
const restoreDom = installHappyDom();
const { registerMonacoDefinitionLinkGesture } = await import("./definition-link");
const { useLspStore } = await import("@/features/editor/lsp/stores/lsp.store");
afterAll(() => restoreDom());
beforeEach(() => {
  available = true;
  preparationFailure = null;
  definitionCalls = 0;
  navigationContext = "java:ready:attachment-1";
  getDefinitionDeferred = null;
});

interface Disposable {
  dispose: () => void;
}

// Minimal stand-ins for the Monaco surfaces the gesture uses. The editor is
// never actually driven here; these tests assert registration-time wiring and
// the live `enabled` gate.
function createStubEditor() {
  const noopDisposable: Disposable = { dispose: () => undefined };
  const editor = {
    createDecorationsCollection: mock(() => ({
      set: () => undefined,
      clear: () => undefined,
    })),
    onMouseMove: mock(() => noopDisposable),
    onMouseLeave: mock(() => noopDisposable),
    onKeyDown: mock(() => noopDisposable),
    onKeyUp: mock(() => noopDisposable),
    onDidChangeModelContent: mock(() => noopDisposable),
    onDidBlurEditorWidget: mock(() => noopDisposable),
  } as unknown as Monaco.editor.IStandaloneCodeEditor;
  return { editor };
}

function createStubModel() {
  return {
    getLanguageId: () => "java",
    isDisposed: () => false,
    getVersionId: () => 1,
    getWordAtPosition: () => null,
  } as unknown as Monaco.editor.ITextModel;
}

// A `.java` document is a supported LSP target, so the gesture is structurally
// capable regardless of the live active/expensive-service state.
const javaTarget = { filePath: "/project/src/Main.java" };

describe("definition link gesture", () => {
  test("registers listeners for a supported document even when inactive", () => {
    const { editor } = createStubEditor();
    const gesture = registerMonacoDefinitionLinkGesture({
      editor,
      model: createStubModel(),
      documentTarget: javaTarget,
      isEnabled: () => false,
    });

    // Listeners are wired against structural capability, so a gesture created
    // while its surface is inactive can still activate later without recreating
    // the editor.
    expect(editor.onMouseMove).toHaveBeenCalled();
    expect(editor.onKeyDown).toHaveBeenCalled();
    expect(gesture.enabled).toBe(false);

    gesture.dispose();
  });

  test("reports enabled live so activation needs no editor rebuild", () => {
    const { editor } = createStubEditor();
    // Regression guard: `enableExpensiveServices` flips on every tab switch and
    // was removed from the editor-creation effect's dependencies. The gesture
    // must therefore read the flag live — registering once while inactive and
    // becoming enabled when the surface activates.
    let expensiveServices = false;
    const gesture = registerMonacoDefinitionLinkGesture({
      editor,
      model: createStubModel(),
      documentTarget: javaTarget,
      isEnabled: () => expensiveServices,
    });

    expect(gesture.enabled).toBe(false);
    expensiveServices = true;
    expect(gesture.enabled).toBe(true);
    expensiveServices = false;
    expect(gesture.enabled).toBe(false);

    gesture.dispose();
  });

  test("stays disabled for an unsupported document", () => {
    const { editor } = createStubEditor();
    const gesture = registerMonacoDefinitionLinkGesture({
      editor,
      model: createStubModel(),
      // A plaintext document has no LSP target, so the gesture is never capable.
      documentTarget: { filePath: "/project/notes.txt" },
      isEnabled: () => true,
    });

    expect(gesture.enabled).toBe(false);
    expect(editor.onMouseMove).not.toHaveBeenCalled();

    gesture.dispose();
  });

  test("rejects an in-flight resolveForClick when the surface becomes inactive", async () => {
    // Regression: before the fix, `resolveForClick` did not check
    // `isGestureActive()` after the `await`. An async click issued on tab A
    // could land its LSP response after the user switched to tab B, and the
    // callback would dispatch a global `editor.goToDefinition` on B's editor.
    // Now `resolveForClick` returns null when the surface is no longer active.
    let active = true;
    getDefinitionDeferred = null;
    const gesture = registerMonacoDefinitionLinkGesture({
      editor: createStubEditor().editor,
      model: {
        getLanguageId: () => "java",
        isDisposed: () => false,
        getVersionId: () => 1,
        getWordAtPosition: () => ({ startColumn: 1, endColumn: 5 }),
      } as unknown as Monaco.editor.ITextModel,
      documentTarget: javaTarget,
      isEnabled: () => active,
    });

    // Start a click resolution while the surface is active.
    const clickPromise = gesture.resolveForClick({ lineNumber: 1, column: 3 } as Monaco.Position);

    // Deactivate the surface while the LSP request is in flight.
    active = false;

    // Let the LSP response land.
    (getDefinitionDeferred as unknown as { resolve: (value: unknown) => void }).resolve([{ uri: "file:///target", range: { start: { line: 0, character: 0 }, end: { line: 0, character: 5 } } }]);

    const hint = await clickPromise;
    // The request should be rejected because the surface is no longer active.
    expect(hint).toBeNull();

    gesture.dispose();
  });

  const targetLocation = (name: string) => [{
    uri: `file:///project/${name}.java`,
    range: { start: { line: 0, character: 0 }, end: { line: 0, character: 5 } },
  }];
  const position = { lineNumber: 1, column: 3 } as Monaco.Position;
  const createClickableGesture = () => registerMonacoDefinitionLinkGesture({
    editor: createStubEditor().editor,
    model: {
      ...createStubModel(),
      getWordAtPosition: () => ({ startColumn: 1, endColumn: 5 }),
      getValue: () => "Main",
    } as unknown as Monaco.editor.ITextModel,
    documentTarget: javaTarget,
    workspaceScope: { workspaceId: "project", root: "/project" },
  });
  const completeDefinition = (locations: unknown) => {
    expect(getDefinitionDeferred).not.toBeNull();
    getDefinitionDeferred!.resolve(locations);
  };

  test.each([{ first: null }, { first: [] }])("retries a transient empty definition without editing the source (%j)", async ({ first }) => {
    const gesture = createClickableGesture();
    try {
      const firstClick = gesture.resolveForClick(position);
      completeDefinition(first);
      expect((await firstClick)?.locations).toEqual([]);
      const secondClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("Recovered"));
      expect((await secondClick)?.locations).toEqual(targetLocation("Recovered"));
      expect(definitionCalls).toBe(2);
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test("retries the same word after preparation fails and the service recovers", async () => {
    const gesture = createClickableGesture();
    try {
      available = false;
      preparationFailure = new Error("Java import failed");
      expect((await gesture.resolveForClick(position))?.locations).toEqual([]);
      expect(definitionCalls).toBe(0);
      available = true;
      preparationFailure = null;
      const recoveredClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("Recovered"));
      expect((await recoveredClick)?.locations).toEqual(targetLocation("Recovered"));
      expect(definitionCalls).toBe(1);
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test.each(["lifecycle", "attachment"])("invalidates successful locations on %s changes", async (change) => {
    const gesture = createClickableGesture();
    try {
      const firstClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("Old"));
      await firstClick;
      expect((await gesture.resolveForClick(position))?.locations).toEqual(targetLocation("Old"));
      expect(definitionCalls).toBe(1);
      navigationContext = `java:ready:new-${change}`;
      const actions = useLspStore.getState().actions;
      if (change === "lifecycle") actions.updateLanguageLifecycle("java", "fullyReady");
      else actions.markDocumentStateChanged();
      const newClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("New"));
      expect((await newClick)?.locations).toEqual(targetLocation("New"));
      expect(definitionCalls).toBe(2);
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test("does not reuse locations after context changes without a store notification", async () => {
    const gesture = createClickableGesture();
    try {
      const firstClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("Old"));
      await firstClick;
      // Capability events and adapter snapshots can change independently of the UI store.
      navigationContext = "java:ready:changed-capabilities";
      const newClick = gesture.resolveForClick(position);
      expect(definitionCalls).toBe(2);
      completeDefinition(targetLocation("New"));
      expect((await newClick)?.locations).toEqual(targetLocation("New"));
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test("discards in-flight locations after context changes without a store notification", async () => {
    const gesture = createClickableGesture();
    try {
      const oldClick = gesture.resolveForClick(position);
      navigationContext = "java:ready:changed-capabilities";
      completeDefinition(targetLocation("Old"));
      expect(await oldClick).toBeNull();
      const newClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("New"));
      expect((await newClick)?.locations).toEqual(targetLocation("New"));
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test("discards in-flight locations when the language service restarts", async () => {
    const gesture = createClickableGesture();
    try {
      const oldClick = gesture.resolveForClick(position);
      navigationContext = "java:starting:attachment-2";
      useLspStore.getState().actions.updateLanguageLifecycle("java", "starting");
      completeDefinition(targetLocation("Old"));
      expect(await oldClick).toBeNull();
      const newClick = gesture.resolveForClick(position);
      completeDefinition(targetLocation("New"));
      expect((await newClick)?.locations).toEqual(targetLocation("New"));
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });
  test("unrelated language-service changes do not discard the active click", async () => {
    const gesture = createClickableGesture();
    try {
      const click = gesture.resolveForClick(position);
      useLspStore.getState().actions.updateLanguageLifecycle("unrelated-typescript", "starting");
      useLspStore.getState().actions.markDocumentStateChanged();
      completeDefinition(targetLocation("Target"));
      expect((await click)?.locations).toEqual(targetLocation("Target"));
      expect(definitionCalls).toBe(1);
    } finally {
      gesture.dispose();
      getDefinitionDeferred?.resolve([]);
    }
  });

  test("disposing the gesture removes its language-service subscription", () => {
    const gesture = createClickableGesture();
    gesture.dispose();
    const readsAfterDispose = navigationContextReads;
    navigationContext = "java:stopped";
    useLspStore.getState().actions.markDocumentStateChanged();
    expect(navigationContextReads).toBe(readsAfterDispose);
  });

});
