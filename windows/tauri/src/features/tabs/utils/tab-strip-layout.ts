import type { Modifier } from "@dnd-kit/core";
import { restrictToHorizontalAxis } from "@dnd-kit/modifiers";
import {
  horizontalListSortingStrategy,
  rectSortingStrategy,
  type SortingStrategy,
} from "@dnd-kit/sortable";
import type { EditorTabLayoutMode } from "@/features/settings/types/settings.types";

export interface TabStripLayout {
  wrapsTabs: boolean;
  // Only a single row overflows horizontally, so wheel scrolling and scrolling the
  // active tab into view apply to that mode alone.
  scrollsHorizontally: boolean;
  sortingStrategy: SortingStrategy;
  dragModifiers: Modifier[];
}

const SINGLE_LINE_LAYOUT: TabStripLayout = {
  wrapsTabs: false,
  scrollsHorizontally: true,
  sortingStrategy: horizontalListSortingStrategy,
  dragModifiers: [restrictToHorizontalAxis],
};

// Dragging stays free on both axes so a tab can move between wrapped rows, as on macOS.
const MULTIPLE_ROWS_LAYOUT: TabStripLayout = {
  wrapsTabs: true,
  scrollsHorizontally: false,
  sortingStrategy: rectSortingStrategy,
  dragModifiers: [],
};

export function getTabStripLayout(mode: EditorTabLayoutMode): TabStripLayout {
  return mode === "multipleRows" ? MULTIPLE_ROWS_LAYOUT : SINGLE_LINE_LAYOUT;
}
