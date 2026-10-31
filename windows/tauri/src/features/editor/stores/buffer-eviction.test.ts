import { afterEach, describe, expect, test } from "bun:test";
import type { PaneContent } from "@/features/panes/types/pane-content.types";
import { markTabActivated, resetTabRecencyForTests } from "@/features/tabs/utils/tab-recency";
import { evictLeastRecentAutoClosableBuffer, selectBuffersOverTabLimit } from "./buffer-eviction";

function tab(id: string, overrides: Record<string, unknown> = {}): PaneContent {
  return { id, type: "editor", path: `/${id}`, isPinned: false, isDirty: false, ...overrides } as PaneContent;
}

const ids = (buffers: PaneContent[]) => buffers.map((buffer) => buffer.id);

afterEach(() => {
  resetTabRecencyForTests();
});

describe("selectBuffersOverTabLimit", () => {
  test("never closes terminals, agents, pinned or unsaved tabs, and does not count them", () => {
    const buffers = [
      tab("terminal", { type: "terminal" }),
      tab("agent", { type: "agent" }),
      tab("conversation", { type: "agentConversation" }),
      tab("pinned", { isPinned: true }),
      tab("dirty", { isDirty: true }),
      tab("a"),
      tab("b"),
    ];

    expect(selectBuffersOverTabLimit(buffers, 2)).toEqual([]);
    expect(ids(selectBuffersOverTabLimit(buffers, 1))).toEqual(["a"]);
  });

  test("treats 0 as no limit", () => {
    expect(selectBuffersOverTabLimit([tab("a"), tab("b")], 0)).toEqual([]);
    const { evictedBuffer } = evictLeastRecentAutoClosableBuffer([tab("a")], 0);
    expect(evictedBuffer).toBeNull();
  });

  test("closes the least recently used tabs by default", () => {
    markTabActivated("a");
    markTabActivated("b");
    markTabActivated("c");
    markTabActivated("a");

    expect(ids(selectBuffersOverTabLimit([tab("a"), tab("b"), tab("c")], 1))).toEqual(["b", "c"]);
  });

  test("closes the oldest opened tabs under that policy", () => {
    markTabActivated("b");
    markTabActivated("a");

    const buffers = [tab("a"), tab("b"), tab("c")];
    expect(ids(selectBuffersOverTabLimit(buffers, 2, { policy: "oldestOpened" }))).toEqual(["a"]);
  });

  test("keeps the requested tab open", () => {
    const buffers = [tab("a"), tab("b")];
    expect(ids(selectBuffersOverTabLimit(buffers, 1, { keepBufferId: "a" }))).toEqual(["b"]);
  });

  test("makes room for a tab about to open", () => {
    const buffers = [tab("a"), tab("b")];
    markTabActivated("a");

    const { buffers: remaining, evictedBuffer } = evictLeastRecentAutoClosableBuffer(buffers, 2);

    expect(evictedBuffer?.id).toBe("b");
    expect(ids(remaining)).toEqual(["a"]);
  });
});
