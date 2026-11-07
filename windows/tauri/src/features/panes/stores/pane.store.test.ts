import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { BOTTOM_PANE_ID, ROOT_PANE_ID } from "../constants/pane";
import { resetCoreRulesForTests } from "@/core/core-rules";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import type { PaneGroup, PaneNode } from "../types/pane.types";

import { usePaneStore } from "./pane.store";

// Counts Core round trips by wrapping the wasm entry point before the real module loads. Every call
// still runs the real rules, so the count is of the same ABI the app uses.
let coreCalls = 0;
const instantiate = WebAssembly.instantiate.bind(WebAssembly);
WebAssembly.instantiate = (async (bytes: BufferSource, imports?: WebAssembly.Imports) => {
  const result = (await instantiate(
    bytes,
    imports,
  )) as unknown as WebAssembly.WebAssemblyInstantiatedSource;
  const exports = result.instance.exports as Record<string, unknown>;
  const execute = exports.lithe_rules_execute as (pointer: number, length: number) => number;
  const counted = {
    ...exports,
    lithe_rules_execute: (pointer: number, length: number) => {
      coreCalls += 1;
      return execute(pointer, length);
    },
  };
  return { module: result.module, instance: { exports: counted } };
}) as unknown as typeof WebAssembly.instantiate;

const WORKSPACE = "pane-store-test";

// An earlier test file in the same Bun process may already hold an unwrapped instance.
beforeAll(async () => {
  resetCoreRulesForTests();
  await loadCoreRulesForTests();
});
afterAll(() => {
  WebAssembly.instantiate = instantiate;
});

beforeEach(() => {
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.ensureWorkspace({ id: WORKSPACE, name: "Panes" }, "ready");
  coreCalls = 0;
});

function store() {
  return usePaneStore.getStore(WORKSPACE);
}

function actions() {
  return store().getState().actions;
}

function group(id: string, bufferIds: string[], activeBufferId: string | null): PaneGroup {
  return { id, type: "group", bufferIds, activeBufferId };
}

function paneIds(root: PaneNode): string[] {
  return root.type === "group" ? [root.id] : root.children.flatMap(paneIds);
}

function openTabs(...bufferIds: string[]) {
  for (const bufferId of bufferIds) actions().addBufferToPane(ROOT_PANE_ID, bufferId);
}

describe("pane store membership rules", () => {
  test("opening, activating and closing tabs follow the shared selection rules", () => {
    openTabs("a", "b", "c");
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      bufferIds: ["a", "b", "c"],
      activeBufferId: "c",
      mruBufferIds: ["c", "b", "a"],
    });

    actions().activatePaneBuffer(ROOT_PANE_ID, "b");
    actions().removeBufferFromPane(ROOT_PANE_ID, "b");
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      bufferIds: ["a", "c"],
      activeBufferId: "c",
    });
  });

  test("closing the last tab of a split pane collapses it and activates the survivor", () => {
    openTabs("a");
    const created = actions().splitPane(ROOT_PANE_ID, "horizontal", "b");
    expect(created).not.toBeNull();
    expect(store().getState().activePaneId).toBe(created as string);

    actions().removeBufferFromPane(created!, "b");
    expect(paneIds(store().getState().root)).toEqual([ROOT_PANE_ID]);
    expect(store().getState().activePaneId).toBe(ROOT_PANE_ID);
  });

  test("closing the last tab of the only pane keeps one empty root pane", () => {
    openTabs("a");
    actions().removeBufferFromPane(ROOT_PANE_ID, "a");
    expect(store().getState().root).toMatchObject({
      id: ROOT_PANE_ID,
      type: "group",
      bufferIds: [],
      activeBufferId: null,
    });
  });

  test("preserving the empty pane keeps the split", () => {
    openTabs("a");
    const created = actions().splitPane(ROOT_PANE_ID, "vertical", "b")!;
    actions().removeBufferFromPane(created, "b", true);
    expect(paneIds(store().getState().root)).toEqual([ROOT_PANE_ID, created]);
    expect(actions().getPaneById(created)?.bufferIds).toEqual([]);
  });

  test("moving a tab between panes empties and closes the source", () => {
    openTabs("a");
    const created = actions().splitPane(ROOT_PANE_ID, "horizontal", "b")!;
    actions().moveBufferToPane("b", created, ROOT_PANE_ID);
    expect(paneIds(store().getState().root)).toEqual([ROOT_PANE_ID]);
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      bufferIds: ["a", "b"],
      activeBufferId: "b",
    });
    expect(store().getState().activePaneId).toBe(ROOT_PANE_ID);
  });

  test("moving a tab to the bottom tree takes it out of the root tree", () => {
    openTabs("a", "b");
    actions().moveBufferToPane("b", ROOT_PANE_ID, BOTTOM_PANE_ID);
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      bufferIds: ["a"],
      activeBufferId: "a",
    });
    expect(actions().getPaneById(BOTTOM_PANE_ID)).toMatchObject({
      bufferIds: ["b"],
      activeBufferId: "b",
    });
    expect(store().getState().activePaneId).toBe(BOTTOM_PANE_ID);
  });

  test("moving the only tab of the root tree out leaves a fresh empty root", () => {
    openTabs("a");
    actions().moveBufferToPane("a", ROOT_PANE_ID, BOTTOM_PANE_ID);
    expect(store().getState().root).toMatchObject({ id: ROOT_PANE_ID, bufferIds: [] });
    expect(actions().getPaneById(BOTTOM_PANE_ID)?.bufferIds).toEqual(["a"]);
  });

  test("closing a pane moves its tabs to the most recent pane and shows its selection", () => {
    openTabs("a");
    const created = actions().splitPane(ROOT_PANE_ID, "horizontal", "b")!;
    actions().addBufferToPane(created, "c");
    actions().closePane(created);
    expect(paneIds(store().getState().root)).toEqual([ROOT_PANE_ID]);
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      bufferIds: ["a", "b", "c"],
      activeBufferId: "c",
    });
    expect(store().getState().activePaneId).toBe(ROOT_PANE_ID);
  });

  test("pins and previews apply across both trees", () => {
    openTabs("a");
    actions().addBufferToPane(BOTTOM_PANE_ID, "a");
    actions().setPanePreviewBuffer(ROOT_PANE_ID, "a");
    actions().setBufferPinnedEverywhere("a", true);
    expect(actions().getPaneById(ROOT_PANE_ID)).toMatchObject({
      pinnedBufferIds: ["a"],
      previewBufferId: null,
    });
    expect(actions().getPaneById(BOTTOM_PANE_ID)?.pinnedBufferIds).toEqual(["a"]);

    actions().setPanePreviewBuffer(BOTTOM_PANE_ID, "a");
    actions().clearPreviewBufferEverywhere("a");
    expect(actions().getPaneById(BOTTOM_PANE_ID)?.previewBufferId).toBeNull();
  });

  test("restoring a layout repairs both trees", () => {
    actions().restoreLayout({
      root: group("r", ["a", "a", "b"], "ghost"),
      bottomRoot: group("t", ["x", "x"], "x"),
      activePaneId: "ghost",
      fullscreenPaneId: null,
    });
    const state = store().getState();
    expect(state.root).toMatchObject({ bufferIds: ["a", "b"], activeBufferId: "a" });
    expect(state.bottomRoot).toMatchObject({ bufferIds: ["x"], activeBufferId: "x" });
  });
});

describe("pane store Core round trips", () => {
  test("every member action makes exactly one Core call", () => {
    openTabs("a", "b");
    const created = actions().splitPane(ROOT_PANE_ID, "horizontal", "c")!;
    actions().addBufferToPane(created, "d");
    actions().addBufferToPane(BOTTOM_PANE_ID, "t");

    const counted: Array<[string, () => void]> = [
      ["addBufferToPane", () => actions().addBufferToPane(ROOT_PANE_ID, "e")],
      ["activatePaneBuffer", () => actions().activatePaneBuffer(ROOT_PANE_ID, "a")],
      ["setPanePreviewBuffer", () => actions().setPanePreviewBuffer(ROOT_PANE_ID, "b")],
      ["setPaneBufferPinned", () => actions().setPaneBufferPinned(ROOT_PANE_ID, "a", true)],
      ["setPaneLocked", () => actions().setPaneLocked(ROOT_PANE_ID, true)],
      ["setBufferPinnedEverywhere", () => actions().setBufferPinnedEverywhere("a", false)],
      ["clearPreviewBufferEverywhere", () => actions().clearPreviewBufferEverywhere("b")],
      ["reorderPaneBuffers", () => actions().reorderPaneBuffers(ROOT_PANE_ID, 0, 1)],
      ["removeBufferFromPane", () => actions().removeBufferFromPane(ROOT_PANE_ID, "e")],
      ["moveBufferToPane", () => actions().moveBufferToPane("d", created, BOTTOM_PANE_ID)],
      [
        "moveBufferToPane across a split",
        () => actions().moveBufferToPane("c", created, ROOT_PANE_ID),
      ],
      ["splitPane", () => actions().splitPane(ROOT_PANE_ID, "vertical", "z")],
      ["closePane", () => actions().closePane(ROOT_PANE_ID)],
      [
        "restoreLayout",
        () =>
          actions().restoreLayout({
            root: store().getState().root,
            bottomRoot: store().getState().bottomRoot,
            activePaneId: store().getState().activePaneId,
            fullscreenPaneId: null,
          }),
      ],
    ];
    for (const [name, run] of counted) {
      coreCalls = 0;
      run();
      expect({ name, coreCalls }).toEqual({ name, coreCalls: 1 });
    }
  });

  test("resizing and distributing splits never call Core", () => {
    openTabs("a");
    const created = actions().splitPane(ROOT_PANE_ID, "horizontal", "b")!;
    const root = store().getState().root;
    if (root.type !== "split") throw new Error("expected a split");
    coreCalls = 0;
    actions().updatePaneSizes(root.id, [30, 70]);
    actions().resizePaneSplit(root.id, 0, [40, 60]);
    actions().distributePaneSplit(root.id);
    actions().setActivePane(created);
    actions().navigateToPane("left");
    actions().togglePaneFullscreen(created);
    expect(coreCalls).toBe(0);
  });
});
