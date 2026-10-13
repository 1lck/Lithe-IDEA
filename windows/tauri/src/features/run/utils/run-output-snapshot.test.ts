import { describe, expect, test } from "bun:test";
import { evictLeastRecentAutoClosableBuffer } from "@/features/editor/stores/buffer-eviction";
import type { EditorContent } from "@/features/panes/types/pane-content.types";
import {
  runOutputSnapshotName,
  runOutputSnapshotPath,
  runOutputSnapshotStamp,
} from "./run-output-snapshot";

describe("run output snapshot naming", () => {
  test("stamps zero-pad each clock component and avoid colons", () => {
    const at = new Date(2026, 8, 24, 7, 5, 3, 123);
    expect(runOutputSnapshotStamp(at)).toBe("07-05-03");
  });

  test("the tab name carries the localized label and the stamp", () => {
    const at = new Date(2026, 8, 24, 16, 33, 18, 400);
    expect(runOutputSnapshotName("输出快照", at)).toBe("输出快照 16-33-18");
  });

  test("consecutive snapshots get distinct virtual paths", () => {
    const earlier = new Date(2026, 8, 24, 16, 33, 18, 100);
    const later = new Date(2026, 8, 24, 16, 33, 19, 100);
    const first = runOutputSnapshotPath(earlier);
    const second = runOutputSnapshotPath(later);
    expect(first.startsWith("lithe-run://snapshot/2026-09-24T16-33-18-")).toBe(true);
    expect(second.startsWith("lithe-run://snapshot/2026-09-24T16-33-19-")).toBe(true);
    expect(first).not.toBe(second);
  });
});

describe("run output snapshot retention", () => {
  const editor = (id: string, isPinned: boolean): EditorContent => ({
    id,
    type: "editor",
    path: `lithe-run://snapshot/${id}`,
    name: `Output snapshot ${id}`,
    content: "frozen lines",
    savedContent: "frozen lines",
    isDirty: false,
    isVirtual: true,
    isPinned,
    isPreview: false,
    isActive: false,
    readOnly: true,
    language: "log",
    tokens: [],
  });

  test("a pinned snapshot survives tab auto-eviction while normal tabs churn", () => {
    // Regression for the review finding: snapshots exist only in memory and
    // their live source lines may already be evicted from the ring buffer,
    // so auto-eviction must never reclaim them.
    const snapshot = editor("snapshot", true);
    const buffers = [
      editor("old-1", false),
      snapshot,
      editor("old-2", false),
      editor("old-3", false),
    ];
    const { buffers: afterFirst, evictedBuffer: first } =
      evictLeastRecentAutoClosableBuffer(buffers, 3);
    expect(first?.id).toBe("old-1");
    expect(afterFirst.some((buffer) => buffer.id === "snapshot")).toBe(true);

    // Keep churning: the snapshot must remain while every unpinned tab cycles.
    let current = afterFirst;
    for (let round = 0; round < 5; round += 1) {
      current = [
        ...current.filter((buffer) => buffer.id !== "snapshot"),
        editor(`churn-${round}`, false),
        snapshot,
      ];
      const result = evictLeastRecentAutoClosableBuffer(current, 3);
      expect(result.evictedBuffer?.id).not.toBe("snapshot");
      expect(result.buffers.some((buffer) => buffer.id === "snapshot")).toBe(true);
      current = result.buffers;
    }
  });

  test("without pinning a snapshot would be evictable, which is why creation pins it", () => {
    const unpinned = editor("unpinned-snapshot", false);
    const { evictedBuffer } = evictLeastRecentAutoClosableBuffer([unpinned], 0);
    expect(evictedBuffer?.id).toBe("unpinned-snapshot");
  });
});
