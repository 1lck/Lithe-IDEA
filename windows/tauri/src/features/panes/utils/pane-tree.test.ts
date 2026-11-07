import { beforeAll, describe, expect, test } from "bun:test";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import type { PaneGroup, PaneNode, PaneSplit } from "../types/pane.types";
import {
  addBufferToPane,
  clearPanePreviewBufferEverywhere,
  createPaneGroup,
  createPaneSplit,
  findPaneGroup,
  getAllPaneGroups,
  mergeClosedPaneInto,
  moveBufferBetweenPanes,
  normalizePaneTree,
  normalizePaneTrees,
  removeBufferFromPane,
  reorderPaneBuffers,
  setActivePaneBuffer,
  setPaneBufferPinned,
  setPaneBufferPinnedEverywhere,
  setPaneLocked,
  setPanePreviewBuffer,
} from "./pane-tree";

// Member rules run through the real wasm build of lithe-core-rules (see workbench-state.test.ts
// for the shared fixture). These tests pin how the tree functions use them.
beforeAll(loadCoreRulesForTests);

function group(
  id: string,
  bufferIds: string[],
  activeBufferId: string | null = bufferIds[0] ?? null,
  extra: Partial<PaneGroup> = {},
): PaneGroup {
  return {
    id,
    type: "group",
    bufferIds,
    activeBufferId,
    mruBufferIds: activeBufferId
      ? [activeBufferId, ...bufferIds.filter((id) => id !== activeBufferId)]
      : bufferIds,
    pinnedBufferIds: [],
    previewBufferId: null,
    ...extra,
  };
}

function split(first: PaneNode, second: PaneNode, id = "split"): PaneSplit {
  return { id, type: "split", direction: "horizontal", children: [first, second], sizes: [50, 50] };
}

function pane(root: PaneNode, id: string): PaneGroup {
  const found = findPaneGroup(root, id);
  if (!found) throw new Error(`pane ${id} missing`);
  return found;
}

describe("createPaneGroup", () => {
  test("de-duplicates tabs and falls back to the first tab when the active one is unknown", () => {
    const created = createPaneGroup(["a", "b", "a"], "ghost");
    expect(created.bufferIds).toEqual(["a", "b"]);
    expect(created.activeBufferId).toBe("a");
    expect(created.mruBufferIds).toEqual(["a", "b"]);
  });

  test("puts the requested active tab first in the MRU order", () => {
    const created = createPaneGroup(["a", "b", "c"], "c");
    expect(created.activeBufferId).toBe("c");
    expect(created.mruBufferIds).toEqual(["c", "a", "b"]);
  });

  test("an empty group has no selection", () => {
    const created = createPaneGroup();
    expect(created).toMatchObject({ bufferIds: [], activeBufferId: null, mruBufferIds: [] });
  });
});

describe("opening and activating tabs", () => {
  test("opening an open tab selects it without duplicating it", () => {
    const root = group("g1", ["a", "b"], "b");
    const next = addBufferToPane(root, "g1", "a") as PaneGroup;
    expect(next.bufferIds).toEqual(["a", "b"]);
    expect(next.activeBufferId).toBe("a");
    expect(next.mruBufferIds).toEqual(["a", "b"]);
  });

  test("opening in the background keeps the selection", () => {
    const next = addBufferToPane(group("g1", ["a"]), "g1", "b", false) as PaneGroup;
    expect(next.bufferIds).toEqual(["a", "b"]);
    expect(next.activeBufferId).toBe("a");
  });

  test("activating an unknown tab leaves the selection alone", () => {
    const next = setActivePaneBuffer(group("g1", ["a", "b"], "b"), "g1", "ghost") as PaneGroup;
    expect(next.activeBufferId).toBe("b");
  });

  test("an unknown pane is a no-op that keeps the same tree", () => {
    const root = group("g1", ["a"]);
    expect(addBufferToPane(root, "nope", "b")).toBe(root);
  });
});

describe("closing tabs", () => {
  test("closing the selected middle tab selects the tab that slid into its place", () => {
    const next = removeBufferFromPane(group("g1", ["a", "b", "c"], "b"), "g1", "b") as PaneGroup;
    expect(next.bufferIds).toEqual(["a", "c"]);
    expect(next.activeBufferId).toBe("c");
  });

  test("closing the selected last tab selects the new last tab", () => {
    const next = removeBufferFromPane(group("g1", ["a", "b", "c"], "c"), "g1", "c") as PaneGroup;
    expect(next.activeBufferId).toBe("b");
  });

  test("closing drops pins and previews that named the tab", () => {
    const root = group("g1", ["a", "b"], "a", {
      pinnedBufferIds: ["a", "b"],
      previewBufferId: "b",
    });
    const next = removeBufferFromPane(root, "g1", "b") as PaneGroup;
    expect(next.pinnedBufferIds).toEqual(["a"]);
    expect(next.previewBufferId).toBeNull();
  });

  test("an emptied pane stays when asked to be preserved", () => {
    const root = split(group("g1", ["a"]), group("g2", ["b"]));
    const next = removeBufferFromPane(root, "g1", "a", false) as PaneSplit;
    expect(getAllPaneGroups(next).map((entry) => entry.id)).toEqual(["g1", "g2"]);
    expect(pane(next, "g1").bufferIds).toEqual([]);
    expect(pane(next, "g1").activeBufferId).toBeNull();
  });

  test("an emptied pane is closed and its sibling takes the whole space", () => {
    const sibling = group("g2", ["b"]);
    const next = removeBufferFromPane(split(group("g1", ["a"]), sibling), "g1", "a", true);
    expect(next).toBe(sibling);
  });

  test("closing the last tab of the only pane reports that the tree is gone", () => {
    expect(removeBufferFromPane(group("g1", ["a"]), "g1", "a", true)).toBeNull();
  });

  test("closing a tab the pane does not hold only repairs it", () => {
    const root = group("g1", ["a", "b"], "ghost", {
      pinnedBufferIds: ["ghost", "a", "a"],
      previewBufferId: "ghost",
    });
    const next = removeBufferFromPane(root, "g1", "zz") as PaneGroup;
    expect(next).toMatchObject({
      bufferIds: ["a", "b"],
      activeBufferId: "a",
      pinnedBufferIds: ["a"],
      previewBufferId: null,
    });
  });
});

describe("moving tabs between panes", () => {
  test("selects the moved tab in the destination and the neighbour in the source", () => {
    const root = split(group("g1", ["a", "b"], "a"), group("g2", ["c"]));
    const { fromRoot, toRoot } = moveBufferBetweenPanes(root, root, "a", "g1", "g2", true);
    expect(toRoot).toBe(fromRoot);
    expect(pane(fromRoot!, "g1")).toMatchObject({ bufferIds: ["b"], activeBufferId: "b" });
    expect(pane(fromRoot!, "g2")).toMatchObject({
      bufferIds: ["c", "a"],
      activeBufferId: "a",
      mruBufferIds: ["a", "c"],
    });
  });

  test("moving the last tab closes the source pane unless it is preserved", () => {
    const target = group("g2", ["c"]);
    const root = split(group("g1", ["a"]), target);
    const closed = moveBufferBetweenPanes(root, root, "a", "g1", "g2", true).fromRoot!;
    expect(closed.type).toBe("group");
    expect((closed as PaneGroup).id).toBe("g2");
    expect((closed as PaneGroup).bufferIds).toEqual(["c", "a"]);

    const kept = moveBufferBetweenPanes(root, root, "a", "g1", "g2", false).fromRoot!;
    expect(getAllPaneGroups(kept).map((entry) => entry.id)).toEqual(["g1", "g2"]);
    expect(pane(kept, "g1").bufferIds).toEqual([]);
  });

  test("moves a tab across two trees with the source tree losing its last pane", () => {
    const rootTree = group("g1", ["a"]);
    const bottomTree = group("g2", ["t"]);
    const moved = moveBufferBetweenPanes(rootTree, bottomTree, "a", "g1", "g2", true);
    expect(moved.fromRoot).toBeNull();
    expect((moved.toRoot as PaneGroup).bufferIds).toEqual(["t", "a"]);
    expect((moved.toRoot as PaneGroup).activeBufferId).toBe("a");
  });

  test("moving to a pane that does not exist keeps the tab where it is", () => {
    const root = group("g1", ["a", "b"]);
    const moved = moveBufferBetweenPanes(root, root, "a", "g1", "ghost", true);
    expect(moved.fromRoot).toBe(root);
  });
});

describe("pins, previews, locking and order", () => {
  test("pinning promotes a previewed tab and previewing releases a pin", () => {
    const pinned = setPaneBufferPinned(
      group("g1", ["a", "b"], "a", { previewBufferId: "b" }),
      "g1",
      "b",
      true,
    ) as PaneGroup;
    expect(pinned.pinnedBufferIds).toEqual(["b"]);
    expect(pinned.previewBufferId).toBeNull();

    const previewed = setPanePreviewBuffer(pinned, "g1", "b") as PaneGroup;
    expect(previewed.pinnedBufferIds).toEqual([]);
    expect(previewed.previewBufferId).toBe("b");
  });

  test("pins and previews touch only the groups that hold the tab", () => {
    const untouched = group("g3", ["b"]);
    const root = split(
      group("g1", ["a", "b"], "a", { previewBufferId: "a" }),
      split(group("g2", ["a"]), untouched, "inner"),
    );
    const [pinned] = setPaneBufferPinnedEverywhere([root], "a", true);
    expect(pane(pinned, "g1")).toMatchObject({ pinnedBufferIds: ["a"], previewBufferId: null });
    expect(pane(pinned, "g2").pinnedBufferIds).toEqual(["a"]);
    expect(pane(pinned, "g3")).toBe(untouched);

    const previewing = split(
      group("g1", ["a"], "a", { previewBufferId: "a" }),
      group("g2", ["a"], "a", { previewBufferId: "a" }),
    );
    const [cleared] = clearPanePreviewBufferEverywhere([previewing], "a");
    expect(getAllPaneGroups(cleared).map((entry) => entry.previewBufferId)).toEqual([null, null]);
  });

  test("locking a pane keeps its tabs and sets the flag", () => {
    const next = setPaneLocked(group("g1", ["a"]), "g1", true) as PaneGroup;
    expect(next.locked).toBe(true);
    expect(next.bufferIds).toEqual(["a"]);
  });

  test("reordering moves one tab and ignores out-of-range indexes", () => {
    const root = group("g1", ["a", "b", "c"], "b");
    const moved = reorderPaneBuffers(root, "g1", 0, 2) as PaneGroup;
    expect(moved.bufferIds).toEqual(["b", "c", "a"]);
    expect(moved.activeBufferId).toBe("b");
    expect(reorderPaneBuffers(root, "g1", -1, 1)).toBe(root);
    expect(reorderPaneBuffers(root, "g1", 0, 3)).toBe(root);
  });
});

describe("closing a pane merges its tabs", () => {
  test("appends the tabs and shows the closed pane's tab only when asked", () => {
    const closing = group("g1", ["a", "b"], "b");
    const target = group("g2", ["c"]);
    const shown = mergeClosedPaneInto(target, closing, "g2", true) as PaneGroup;
    expect(shown.bufferIds).toEqual(["c", "a", "b"]);
    expect(shown.activeBufferId).toBe("b");
    expect(shown.mruBufferIds).toEqual(["b", "c", "a"]);

    const background = mergeClosedPaneInto(target, closing, "g2", false) as PaneGroup;
    expect(background.activeBufferId).toBe("c");
  });
});

describe("normalizing trees", () => {
  test("repairs every group of several trees and also the split ratios", () => {
    const broken = split(
      group("g1", ["a", "a", "b"], "ghost", {
        mruBufferIds: ["ghost", "b"],
        pinnedBufferIds: ["ghost", "b", "b"],
        previewBufferId: "ghost",
      }),
      group("g2", []),
    );
    broken.sizes = [0, 100];
    const [fixed, other] = normalizePaneTrees([broken, group("g3", ["x", "x"], "x")]);
    expect(pane(fixed, "g1")).toMatchObject({
      bufferIds: ["a", "b"],
      activeBufferId: "a",
      mruBufferIds: ["a", "b"],
      pinnedBufferIds: ["b"],
      previewBufferId: null,
    });
    expect(pane(fixed, "g2")).toMatchObject({ bufferIds: [], activeBufferId: null });
    expect((fixed as PaneSplit).sizes[0]).toBeGreaterThan(0);
    expect((other as PaneGroup).bufferIds).toEqual(["x"]);
    expect(normalizePaneTree(group("g4", ["y", "y"]))).toMatchObject({ bufferIds: ["y"] });
  });

  test("new splits get a normalized group", () => {
    const created = createPaneGroup(["a", "a"], "a");
    const tree = createPaneSplit("horizontal", group("g1", ["b"]), created);
    expect(getAllPaneGroups(tree)[1].bufferIds).toEqual(["a"]);
  });
});
