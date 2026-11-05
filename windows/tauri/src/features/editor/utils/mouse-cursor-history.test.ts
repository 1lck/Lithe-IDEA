import { afterEach, describe, expect, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import { useJumpListStore } from "../stores/jump-list.store";
import { type CursorHistoryEntry, recordMouseGesture } from "./mouse-cursor-history";

function entry(line: number, column: number): CursorHistoryEntry {
  return {
    bufferId: "buffer-a",
    filePath: "C:/workspace/a.ts",
    line,
    column,
    offset: line * 100 + column,
    scrollTop: line * 10,
    scrollLeft: column,
  };
}

afterEach(() => useJumpListStore.getState().actions.clear());

describe("mouse cursor history", () => {
  test("sends one record event per completed gesture", async () => {
    const reduce = spyOn(core, "invoke").mockImplementation((async (_command, args) => ({
      state: (args as { state: unknown }).state,
      destination: null,
    })) as typeof core.invoke);
    try {
      recordMouseGesture(entry(10, 20), entry(20, 5));
      await useJumpListStore.getState().actions.goBack();
      expect(reduce.mock.calls[0]).toEqual([
        "editor.navigationHistory.reduce",
        {
          state: { back: [], forward: [] },
          event: {
            type: "record",
            departure: {
              document: "C:/workspace/a.ts",
              line: 10,
              column: 20,
              context: { bufferId: "buffer-a", offset: 1020, scrollTop: 100, scrollLeft: 20 },
            },
            destination: {
              document: "C:/workspace/a.ts",
              line: 20,
              column: 5,
              context: { bufferId: "buffer-a", offset: 2005, scrollTop: 200, scrollLeft: 5 },
            },
          },
        },
      ]);
    } finally {
      reduce.mockRestore();
    }
  });

  test("skips a gesture without a known start or end position", () => {
    const reduce = spyOn(core, "invoke");
    try {
      recordMouseGesture(null, entry(20, 5));
      recordMouseGesture(entry(10, 20), null);
      expect(reduce).not.toHaveBeenCalled();
    } finally {
      reduce.mockRestore();
    }
  });
});
