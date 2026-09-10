import { afterAll, afterEach, beforeAll, describe, expect, mock, spyOn, test } from "bun:test";
import type { JumpListEntry } from "@/features/editor/stores/jump-list.store";
import { usePaneStore } from "@/features/panes/stores/pane.store";

type OwnerNavigationResult = "applied" | "pending";

interface MockPane {
  id: string;
}

const focus = mock(() => undefined);
const focusWhenReady = mock(() => undefined);
const cancelPendingOwnerNavigation = mock(() => undefined);
let activatedPaneId: string | null = "pane-a";
let navigationResults: OwnerNavigationResult[] = [];
let panesById = new Map<string, MockPane>();
let panesByBufferId = new Map<string, MockPane>();
let activePane: MockPane | null = null;

const navigateToPositionForOwner = mock(
  (): OwnerNavigationResult => navigationResults.shift() ?? "applied",
);
const activateBufferInPaneAndSync = mock(
  (_paneId: string, _bufferId: string): string | null => activatedPaneId,
);
const getPaneById = mock((paneId: string): MockPane | null => panesById.get(paneId) ?? null);
const getPaneByBufferId = mock((bufferId: string): MockPane | null => {
  return panesByBufferId.get(bufferId) ?? null;
});
const getActivePane = mock((): MockPane | null => activePane);
const getPaneState = spyOn(usePaneStore, "getState").mockImplementation(
  () =>
    ({
      activePaneId: activePane?.id ?? "",
      actions: {
        getPaneById,
        getPaneByBufferId,
        getActivePane,
      },
    }) as unknown as ReturnType<typeof usePaneStore.getState>,
);

const targetBuffer = {
  id: "buffer-a",
  path: "src/example.ts",
};

mock.module("@/features/editor/extensions/api", () => ({
  editorAPI: {
    focus,
    focusWhenReady,
    navigateToPositionForOwner,
    cancelPendingOwnerNavigation,
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
mock.module("@/features/editor/utils/buffer-index", () => ({
  getBufferById: (buffers: Array<typeof targetBuffer>, id: string) =>
    buffers.find((buffer) => buffer.id === id),
  getBufferByPath: (buffers: Array<typeof targetBuffer>, path: string) =>
    buffers.find((buffer) => buffer.path === path),
}));
mock.module("@/features/file-system/controllers/file-operations", () => ({
  readFileContent: mock(() => Promise.resolve("")),
}));
mock.module("@/features/panes/utils/pane-activation", () => ({
  activateBufferInPaneAndSync,
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
let nextAnimationFrameId = 1;
const animationFrames = new Map<number, FrameRequestCallback>();

function runNextAnimationFrame(): void {
  const next = animationFrames.entries().next().value as
    | [number, FrameRequestCallback]
    | undefined;
  if (!next) throw new Error("Expected a queued animation frame");

  const [id, callback] = next;
  animationFrames.delete(id);
  callback(0);
}

async function drainNavigation(navigation: Promise<boolean>): Promise<boolean> {
  let settled = false;
  let result: boolean | undefined;
  let failure: unknown;

  void navigation.then(
    (value) => {
      settled = true;
      result = value;
    },
    (error: unknown) => {
      settled = true;
      failure = error;
    },
  );

  for (let frameCount = 0; frameCount < 4; frameCount += 1) {
    for (let microtaskCount = 0; microtaskCount < 8; microtaskCount += 1) {
      await Promise.resolve();
    }

    if (settled) {
      if (failure) throw failure;
      return result ?? false;
    }

    if (animationFrames.size === 0) {
      throw new Error("Navigation neither settled nor scheduled an animation frame");
    }
    runNextAnimationFrame();
  }

  throw new Error("Navigation did not settle after four controlled animation frames");
}

function configurePanes({
  active,
  byId = [],
  byBufferId = [],
}: {
  active: MockPane | null;
  byId?: MockPane[];
  byBufferId?: Array<[string, MockPane]>;
}): void {
  activePane = active;
  panesById = new Map(byId.map((pane) => [pane.id, pane]));
  panesByBufferId = new Map(byBufferId);
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
  focus.mockClear();
  focusWhenReady.mockClear();
  cancelPendingOwnerNavigation.mockClear();
  navigateToPositionForOwner.mockClear();
  activateBufferInPaneAndSync.mockClear();
  getPaneById.mockClear();
  getPaneByBufferId.mockClear();
  getActivePane.mockClear();
  getPaneState.mockClear();
  activatedPaneId = "pane-a";
  navigationResults = [];
  configurePanes({ active: null });
  animationFrames.clear();
});

afterAll(() => {
  globalThis.requestAnimationFrame = originalRequestAnimationFrame;
  mock.restore();
});

describe("navigateToJumpEntry", () => {
  test("uses the owner-directed navigation path after activating the history pane", async () => {
    configurePanes({
      active: { id: "pane-a" },
      byId: [{ id: "pane-a" }],
    });

    const didNavigate = await drainNavigation(navigateToJumpEntry(entry));

    expect(didNavigate).toBe(true);
    expect(activateBufferInPaneAndSync).toHaveBeenCalledWith("pane-a", "buffer-a");
    expect(focusWhenReady).toHaveBeenCalledWith("pane-a:buffer-a");
    expect(navigateToPositionForOwner).toHaveBeenCalledWith(
      "pane-a:buffer-a",
      { line: 8, column: 12, offset: 123 },
      240,
      16,
    );
    expect(focus).toHaveBeenCalledWith("pane-a:buffer-a");
  });

  test("fails and cancels the pending owner navigation when the adapter stays unavailable", async () => {
    configurePanes({
      active: { id: "pane-a" },
      byId: [{ id: "pane-a" }],
    });
    navigationResults = ["pending", "pending"];

    const didNavigate = await drainNavigation(navigateToJumpEntry(entry));

    expect(didNavigate).toBe(false);
    expect(navigateToPositionForOwner).toHaveBeenCalledTimes(2);
    expect(cancelPendingOwnerNavigation).toHaveBeenCalledWith("pane-a:buffer-a");
    expect(focus).not.toHaveBeenCalled();
  });

  test("routes a closed history pane to the live pane that still contains the buffer", async () => {
    const livePane = { id: "pane-live" };
    configurePanes({
      active: { id: "pane-current" },
      byId: [{ id: "pane-current" }],
      byBufferId: [[targetBuffer.id, livePane]],
    });
    activatedPaneId = livePane.id;

    const didNavigate = await drainNavigation(
      navigateToJumpEntry({ ...entry, paneId: "pane-closed" }),
    );

    expect(didNavigate).toBe(true);
    expect(activateBufferInPaneAndSync).toHaveBeenCalledWith(livePane.id, targetBuffer.id);
    expect(navigateToPositionForOwner).toHaveBeenCalledWith(
      `${livePane.id}:${targetBuffer.id}`,
      { line: 8, column: 12, offset: 123 },
      240,
      16,
    );
    expect(focusWhenReady).toHaveBeenCalledWith(`${livePane.id}:${targetBuffer.id}`);
  });

  test("fails without scheduling navigation when neither the history pane nor a fallback pane exists", async () => {
    configurePanes({ active: null });

    const didNavigate = await drainNavigation(
      navigateToJumpEntry({ ...entry, paneId: "pane-closed" }),
    );

    expect(didNavigate).toBe(false);
    expect(activateBufferInPaneAndSync).not.toHaveBeenCalled();
    expect(navigateToPositionForOwner).not.toHaveBeenCalled();
    expect(focusWhenReady).not.toHaveBeenCalled();
    expect(animationFrames.size).toBe(0);
  });
});
