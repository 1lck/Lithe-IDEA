import { afterEach, describe, expect, spyOn, test } from "bun:test";
import * as core_ from "@/platform/tauri-core";
import {
  type JumpListEntry,
  type NavigationHistoryState,
  useJumpListStore,
} from "./jump-list.store";

function entry(line: number, column: number, paneId?: string): JumpListEntry {
  return {
    bufferId: "buffer-a",
    filePath: "C:/workspace/a.ts",
    paneId,
    line,
    column,
    offset: line * 100 + column,
    scrollTop: line * 10,
    scrollLeft: column,
  };
}

function location(line: number, column: number, paneId?: string) {
  const { filePath, line: entryLine, column: entryColumn, ...context } = entry(line, column, paneId);
  return { document: filePath, line: entryLine, column: entryColumn, context };
}

type Reduce = (args: { state: NavigationHistoryState; event: { type: string } }) => unknown;

function mockCore(reduce: Reduce) {
  return spyOn(core_, "invoke").mockImplementation((async (command, args) => {
    expect(command).toBe("editor.navigationHistory.reduce");
    return reduce(args as Parameters<Reduce>[0]);
  }) as typeof core_.invoke);
}

afterEach(() => useJumpListStore.getState().actions.clear());

describe("jump list backed by Core navigation history", () => {
  test("records through Core and installs the returned state", async () => {
    const core = mockCore(() => ({ state: { back: [location(9, 19, "left")], forward: [] }, destination: null }));
    try {
      await useJumpListStore.getState().actions.record(entry(9, 19, "left"), entry(30, 1, "left"));
      expect(core.mock.calls[0]?.[1]).toEqual({
        state: { back: [], forward: [] },
        event: { type: "record", departure: location(9, 19, "left"), destination: location(30, 1, "left") },
      });
      expect(useJumpListStore.getState().history.back).toEqual([location(9, 19, "left")]);
      expect(useJumpListStore.getState().actions.canGoBack()).toBe(true);
      expect(useJumpListStore.getState().actions.canGoForward()).toBe(false);
    } finally {
      core.mockRestore();
    }
  });

  test("applies events in order to the state produced by the previous event", async () => {
    const seen: NavigationHistoryState[] = [];
    const core = mockCore(({ state }) => {
      seen.push(state);
      return { state: { back: [...state.back, location(seen.length, 0)], forward: [] }, destination: null };
    });
    try {
      const actions = useJumpListStore.getState().actions;
      await Promise.all([actions.record(entry(1, 0)), actions.record(entry(2, 0))]);
      expect(seen).toEqual([
        { back: [], forward: [] },
        { back: [location(1, 0)], forward: [] },
      ]);
    } finally {
      core.mockRestore();
    }
  });

  test("returns the Core destination with its pane and scroll context", async () => {
    const core = mockCore(({ event }) => ({
      state: { back: [], forward: event.type === "back" ? [location(49, 1, "right")] : [] },
      destination: location(39, 1, "right"),
    }));
    try {
      const step = await useJumpListStore.getState().actions.goBack(entry(49, 1, "right"));
      expect(step?.entry).toEqual(entry(39, 1, "right"));
      expect(core.mock.calls[0]?.[1]).toMatchObject({ event: { type: "back", current: location(49, 1, "right") } });
    } finally {
      core.mockRestore();
    }
  });

  test("rolls a failed step back only while no newer event replaced it", async () => {
    const original = { back: [location(9, 1)], forward: [] };
    useJumpListStore.setState({ history: original });
    let call = 0;
    const core = mockCore(() => {
      call += 1;
      return call < 3
        ? { state: { back: [], forward: [location(19, 1)] }, destination: location(9, 1) }
        : { state: { back: [location(5, 0)], forward: [] }, destination: null };
    });
    try {
      const actions = useJumpListStore.getState().actions;
      const step = await actions.goBack(entry(19, 1));
      expect(step).not.toBeNull();
      actions.rollback(step!);
      expect(useJumpListStore.getState().history).toBe(original);

      const repeated = await actions.goBack(entry(19, 1));
      await actions.record(entry(5, 0));
      actions.rollback(repeated!);
      expect(useJumpListStore.getState().history).toEqual({ back: [location(5, 0)], forward: [] });
    } finally {
      core.mockRestore();
    }
  });

  test("keeps the history when Core rejects the event", async () => {
    const original = { back: [location(9, 1)], forward: [] };
    useJumpListStore.setState({ history: original });
    const core = spyOn(core_, "invoke").mockRejectedValue(new Error("invalid_request"));
    try {
      expect(await useJumpListStore.getState().actions.goBack(entry(19, 1))).toBeNull();
      expect(useJumpListStore.getState().history).toBe(original);
    } finally {
      core.mockRestore();
    }
  });
});
