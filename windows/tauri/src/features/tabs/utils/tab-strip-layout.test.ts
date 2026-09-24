import { describe, expect, test } from "bun:test";
import { restrictToHorizontalAxis } from "@dnd-kit/modifiers";
import { horizontalListSortingStrategy, rectSortingStrategy } from "@dnd-kit/sortable";
import { getTabStripLayout } from "./tab-strip-layout";

describe("editor tab strip layout", () => {
  test("keeps a single scrolling row with horizontal-only dragging", () => {
    const layout = getTabStripLayout("singleLine");

    expect(layout.wrapsTabs).toBe(false);
    expect(layout.scrollsHorizontally).toBe(true);
    expect(layout.sortingStrategy).toBe(horizontalListSortingStrategy);
    expect(layout.dragModifiers).toEqual([restrictToHorizontalAxis]);
  });

  test("wraps into rows and lets tabs be dragged between rows", () => {
    const layout = getTabStripLayout("multipleRows");

    expect(layout.wrapsTabs).toBe(true);
    expect(layout.scrollsHorizontally).toBe(false);
    expect(layout.sortingStrategy).toBe(rectSortingStrategy);
    expect(layout.dragModifiers).toEqual([]);
  });
});
