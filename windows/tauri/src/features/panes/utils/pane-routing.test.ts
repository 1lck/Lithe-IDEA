import { describe, expect, test } from "bun:test";
import type { PaneGroup, PaneNode } from "../types/pane.types";
import { resolveMainPaneForExternalOpen } from "./pane-routing";

const pane = (id: string): PaneGroup => ({
  id,
  type: "group",
  bufferIds: [],
  activeBufferId: null,
});

describe("main pane routing for external opens", () => {
  test("keeps an active main editor pane", () => {
    const mainPane = pane("main");

    expect(
      resolveMainPaneForExternalOpen({
        activePaneId: "main",
        mostRecentActivePaneIds: ["main"],
        root: mainPane,
      }),
    ).toBe(mainPane);
  });

  test("routes away from the bottom pane to the most recent main pane", () => {
    const firstPane = pane("first");
    const recentPane = pane("recent");
    const root: PaneNode = {
      id: "main-split",
      type: "split",
      direction: "horizontal",
      children: [firstPane, recentPane],
      sizes: [50, 50],
    };

    expect(
      resolveMainPaneForExternalOpen({
        activePaneId: "bottom-pane",
        mostRecentActivePaneIds: ["bottom-pane", "recent", "first"],
        root,
      }),
    ).toBe(recentPane);
  });

  test("falls back to the first main pane when history has no main pane", () => {
    const firstPane = pane("first");
    const secondPane = pane("second");
    const root: PaneNode = {
      id: "main-split",
      type: "split",
      direction: "vertical",
      children: [firstPane, secondPane],
      sizes: [50, 50],
    };

    expect(
      resolveMainPaneForExternalOpen({
        activePaneId: "bottom-pane",
        mostRecentActivePaneIds: ["bottom-pane"],
        root,
      }),
    ).toBe(firstPane);
  });
});
