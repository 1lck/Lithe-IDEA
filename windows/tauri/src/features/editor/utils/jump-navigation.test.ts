import { afterAll, afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import type { JumpListEntry } from "@/features/editor/stores/jump-list.store";

const focus = mock(() => undefined);
const focusWhenReady = mock(() => undefined);
const clearSelectionForNavigation = mock(() => undefined);
const setCursorPosition = mock(() => undefined);
const setScroll = mock(() => undefined);
const activateBufferInPaneAndSync = mock(() => undefined);

const targetBuffer = {
  id: "buffer-a",
  path: "src/example.ts",
};

mock.module("@/features/editor/extensions/api", () => ({
  editorAPI: {
    focus,
    focusWhenReady,
    clearSelectionForNavigation,
    setCursorPosition,
  },
}));
mock.module("@/features/editor/stores/buffer.store", () => ({
  useBufferStore: {
    getState: () => ({
      buffers: [targetBuffer],
      actions: {
        openBuffer: mock(() => targetBuffer.id),
      },
    }),
  },
}));
mock.module("@/features/editor/stores/state.store", () => ({
  useEditorStateStore: {
    getState: () => ({
      actions: { setScroll },
    }),
  },
}));
mock.module("@/features/editor/utils/buffer-index", () => ({
  getBufferById: (buffers: Array<typeof targetBuffer>, id: string) =>
    buffers.find((buffer) => buffer.id === id),
  getBufferByPath: (buffers: Array<typeof targetBuffer>, path: string) =>
    buffers.find((buffer) => buffer.path === path),
}));
mock.module("@/features/file-system/controllers/file-operations", () => ({
  readFileContent: mock(() => Promise.resolve("")),
}));
mock.module("@/features/panes/stores/pane.store", () => ({
  usePaneStore: {
    getState: () => ({ activePaneId: "pane-a" }),
  },
}));
mock.module("@/features/panes/utils/pane-activation", () => ({
  activateBufferInPaneAndSync,
}));
mock.module("./logger", () => ({
  logger: {
    error: mock(() => undefined),
    info: mock(() => undefined),
  },
}));

const { navigateToJumpEntry } = await import("./jump-navigation");

const entry: JumpListEntry = {
  bufferId: targetBuffer.id,
  filePath: targetBuffer.path,
  paneId: "pane-a",
  line: 8,
  column: 12,
  offset: 123,
  scrollTop: 240,
  scrollLeft: 16,
  timestamp: 0,
};

const originalRequestAnimationFrame = globalThis.requestAnimationFrame;

beforeAll(() => {
  globalThis.requestAnimationFrame = (callback) => {
    queueMicrotask(() => callback(performance.now()));
    return 0;
  };
});

afterEach(() => {
  focus.mockClear();
  focusWhenReady.mockClear();
  clearSelectionForNavigation.mockClear();
  setCursorPosition.mockClear();
  setScroll.mockClear();
  activateBufferInPaneAndSync.mockClear();
});

afterAll(() => {
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
});

describe("navigateToJumpEntry", () => {
  test("targets focus at the destination pane after activation finishes", async () => {
    await navigateToJumpEntry(entry);

    expect(activateBufferInPaneAndSync).toHaveBeenCalledWith("pane-a", "buffer-a");
    expect(focusWhenReady).toHaveBeenCalledWith("pane-a:buffer-a");
    expect(focus).toHaveBeenNthCalledWith(1, "pane-a:buffer-a");
    expect(focus).toHaveBeenNthCalledWith(2, "pane-a:buffer-a");
  });
});
