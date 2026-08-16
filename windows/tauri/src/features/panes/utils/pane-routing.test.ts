import { describe, expect, test } from "bun:test";
import type { PaneGroup, PaneNode } from "../types/pane.types";
import { resolveMainPaneForBufferOpen, resolveMainPaneForExternalOpen } from "./pane-routing";

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

describe("main pane routing for file buffer opens", () => {
  test("reuses the main pane that already contains the buffer", () => {
    const activePane = pane("active");
    const paneWithBuffer = { ...pane("with-buffer"), bufferIds: ["buffer-a"] };
    const root: PaneNode = {
      id: "main-split",
      type: "split",
      direction: "horizontal",
      children: [activePane, paneWithBuffer],
      sizes: [50, 50],
    };

    expect(
      resolveMainPaneForBufferOpen({
        activePaneId: "active",
        bufferId: "buffer-a",
        mostRecentActivePaneIds: ["active", "with-buffer"],
        root,
      }),
    ).toBe(paneWithBuffer);
  });

  test("routes a buffer found only outside the main tree into a visible main pane", () => {
    const mainPane = pane("main");

    expect(
      resolveMainPaneForBufferOpen({
        activePaneId: "bottom-pane",
        bufferId: "buffer-a",
        mostRecentActivePaneIds: ["bottom-pane", "main"],
        root: mainPane,
      }),
    ).toBe(mainPane);
  });
});
