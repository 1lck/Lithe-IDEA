import { afterAll, afterEach, beforeAll, describe, expect, mock, test } from "bun:test";

const clearSelection = mock(() => undefined);
const setCursorPosition = mock(() => undefined);
const setSelection = mock(() => undefined);
const setScroll = mock(() => undefined);

mock.module("../stores/state.store", () => ({
  useEditorStateStore: {
    getState: () => ({
      actions: {
        setCursorPosition,
        setSelection,
        setScroll,
      },
    }),
  },
}));

const { editorAPI } = await import("./api");

const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
let nextAnimationFrameId = 1;
const animationFrames = new Map<number, FrameRequestCallback>();

function runNextAnimationFrame(): void {
  const next = animationFrames.entries().next().value as
    | [number, FrameRequestCallback]
    | undefined;
  if (!next) throw new Error("Expected a queued animation frame");

  const [id, callback] = next;
  animationFrames.delete(id);
  callback(performance.now());
}

beforeAll(() => {
  globalThis.requestAnimationFrame = (callback) => {
    const id = nextAnimationFrameId;
    nextAnimationFrameId += 1;
    animationFrames.set(id, callback);
    return id;
  };
});

afterEach(() => {
  clearSelection.mockClear();
  setCursorPosition.mockClear();
  setSelection.mockClear();
  setScroll.mockClear();
  animationFrames.clear();
  editorAPI.clearActiveEditorAdapter("preview:buffer-a");
  editorAPI.clearActiveEditorAdapter("pane-a:buffer-a");
  editorAPI.clearActiveEditorAdapter("pane-b:buffer-b");
});

afterAll(() => {
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
  mock.restore();
});

describe("owner-directed navigation", () => {
  test("applies a pending navigation when a read-only surface registers its adapter", () => {
    const ownerId = "preview:buffer-a";
    const navigationResult = editorAPI.navigateToPositionForOwner(
      ownerId,
      { line: 8, column: 12, offset: 123 },
      240,
      16,
    );

    expect(navigationResult).toBe("pending");

    const readOnlyInsert = mock(() => undefined);
    const readOnlyDelete = mock(() => undefined);
    const readOnlyReplace = mock(() => undefined);
    const adapterClearSelection = mock(() => undefined);
    const adapterSetCursor = mock(() => undefined);
    const adapterSetScroll = mock(() => undefined);

    editorAPI.setActiveEditorAdapter({
      ownerId,
      insertText: readOnlyInsert,
      deleteRange: readOnlyDelete,
      replaceRange: readOnlyReplace,
      selectAll: () => undefined,
      clearSelection: adapterClearSelection,
      setCursorPosition: adapterSetCursor,
      setScroll: adapterSetScroll,
      focus: () => undefined,
      undo: () => undefined,
      redo: () => undefined,
    });

    runNextAnimationFrame();

    expect(adapterClearSelection).toHaveBeenCalledTimes(1);
    expect(adapterSetCursor).toHaveBeenCalledWith({ line: 8, column: 12, offset: 123 });
    expect(adapterSetScroll).toHaveBeenCalledWith(240, 16);
    expect(setCursorPosition).toHaveBeenCalledWith(
      { line: 8, column: 12, offset: 123 },
      { ensureVisible: false, viewKey: ownerId },
    );
    expect(setSelection).toHaveBeenCalledWith(undefined, ownerId);
    expect(setScroll).toHaveBeenCalledWith(240, 16, ownerId);
  });

  test("does not let a stale owner registration consume a newer pending navigation", () => {
    const adapterAClearSelection = mock(() => undefined);
    const adapterASetCursor = mock(() => undefined);
    const adapterASetScroll = mock(() => undefined);
    const adapterBClearSelection = mock(() => undefined);
    const adapterBSetCursor = mock(() => undefined);
    const adapterBSetScroll = mock(() => undefined);

    expect(
      editorAPI.navigateToPositionForOwner(
        "pane-a:buffer-a",
        { line: 3, column: 4, offset: 34 },
        48,
        5,
      ),
    ).toBe("pending");
    editorAPI.setActiveEditorAdapter({
      ownerId: "pane-a:buffer-a",
      insertText: () => undefined,
      deleteRange: () => undefined,
      replaceRange: () => undefined,
      selectAll: () => undefined,
      clearSelection: adapterAClearSelection,
      setCursorPosition: adapterASetCursor,
      setScroll: adapterASetScroll,
      focus: () => undefined,
      undo: () => undefined,
      redo: () => undefined,
    });

    expect(
      editorAPI.navigateToPositionForOwner(
        "pane-b:buffer-b",
        { line: 9, column: 10, offset: 98 },
        180,
        12,
      ),
    ).toBe("pending");
    editorAPI.setActiveEditorAdapter({
      ownerId: "pane-b:buffer-b",
      insertText: () => undefined,
      deleteRange: () => undefined,
      replaceRange: () => undefined,
      selectAll: () => undefined,
      clearSelection: adapterBClearSelection,
      setCursorPosition: adapterBSetCursor,
      setScroll: adapterBSetScroll,
      focus: () => undefined,
      undo: () => undefined,
      redo: () => undefined,
    });

    runNextAnimationFrame();
    expect(adapterAClearSelection).not.toHaveBeenCalled();
    expect(adapterASetCursor).not.toHaveBeenCalled();
    expect(adapterASetScroll).not.toHaveBeenCalled();

    runNextAnimationFrame();
    expect(adapterBClearSelection).toHaveBeenCalledTimes(1);
    expect(adapterBSetCursor).toHaveBeenCalledWith({ line: 9, column: 10, offset: 98 });
    expect(adapterBSetScroll).toHaveBeenCalledWith(180, 12);
  });
});
