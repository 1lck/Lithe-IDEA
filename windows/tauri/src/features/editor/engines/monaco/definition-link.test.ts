import { afterAll, describe, expect, mock, test } from "bun:test";
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
// reads `window.__TAURI_INTERNALS__` at module scope. They are only touched
// inside the scheduler's resolve callback, which these tests never trigger, so
// stub them to keep the unit test free of the native host.
mock.module("@/features/editor/lsp/lsp-client", () => ({
  isDocumentFeatureAvailable: () => false,
  LspClient: { getInstance: () => ({}) },
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
afterAll(() => restoreDom());

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
});