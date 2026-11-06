import { beforeAll, describe, expect, test } from "bun:test";
import type { PaneContent } from "@/features/panes/types/pane-content.types";
import type { PaneGroup } from "@/features/panes/types/pane.types";
import { normalizePaneTrees } from "@/features/panes/utils/pane-tree";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import { buildPaneLayoutFromSession } from "./workspace-pane-session";

// Pane groups are repaired by Core when the layout is restored (see pane.store restoreLayout), so
// the session builder only has to hand over the buffers in order.
beforeAll(loadCoreRulesForTests);

function terminal(id: string, isActive = false): PaneContent {
  return { id, type: "terminal", path: `terminal:${id}`, isActive } as unknown as PaneContent;
}

describe("buildPaneLayoutFromSession", () => {
  test("puts buffers missing from the saved layout in the root pane with the active one selected", () => {
    const layout = buildPaneLayoutFromSession(null, [
      terminal("a"),
      terminal("b", true),
      terminal("c"),
    ]);
    const [root] = normalizePaneTrees([layout.root]);
    expect(root).toMatchObject({
      bufferIds: ["b", "a", "c"],
      activeBufferId: "b",
      mruBufferIds: ["b", "a", "c"],
    } satisfies Partial<PaneGroup>);
  });

  test("drops saved paths that no longer resolve and keeps the saved selection", () => {
    const layout = buildPaneLayoutFromSession(
      {
        root: {
          id: "root",
          type: "group",
          bufferPaths: ["terminal:a", "terminal:gone", "terminal:b"],
          activeBufferPath: "terminal:b",
        },
        bottomRoot: { id: "bottom", type: "group", bufferPaths: [] },
        activePaneId: "root",
        fullscreenPaneId: null,
      } as unknown as Parameters<typeof buildPaneLayoutFromSession>[0],
      [terminal("a"), terminal("b")],
    );
    const [root] = normalizePaneTrees([layout.root]);
    expect(root).toMatchObject({ bufferIds: ["a", "b"], activeBufferId: "b" });
  });
});
