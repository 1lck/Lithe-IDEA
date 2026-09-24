import { describe, expect, test } from "bun:test";
import {
  FOOTER_TRAILING_ITEM_IDS,
  SIDEBAR_ACTIVITY_ITEM_IDS,
  SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS,
  normalizeItemOrder,
  setSidebarActivityItemVisibility,
  sidebarActivityVisibilityItemIds,
} from "./item-order";

describe("footer item order", () => {
  test("keeps editor status chips on the trailing status row without Database or Git Log", () => {
    const ordered = normalizeItemOrder(["notifications"], FOOTER_TRAILING_ITEM_IDS);

    expect(ordered).not.toContain("terminal");
    expect(ordered).not.toContain("diagnostics");
    expect(ordered).not.toContain("run");
    expect(ordered).not.toContain("gitLog");
    expect(ordered).not.toContain("databases");
    expect(ordered).toContain("gitChanges");
    expect(ordered).toContain("cursor");
    expect(ordered).toContain("memory");
    expect(ordered).not.toContain("notifications");
  });
});

describe("sidebar activity order", () => {
  test("keeps the right Maven tool window out of the left sidebar order", () => {
    expect(
      sidebarActivityVisibilityItemIds({
        search: true,
        git: true,
        terminal: true,
        diagnostics: true,
      }),
    ).toEqual(["files", "git", "search", "run", "terminal", "diagnostics", "gitLog", "settings"]);
    expect([...SIDEBAR_ACTIVITY_ITEM_IDS]).not.toContain("maven");
  });

  test("hides and restores Run independently", () => {
    const hidden = setSidebarActivityItemVisibility([], "run", false);

    expect(hidden).toEqual(["run"]);
    expect(setSidebarActivityItemVisibility(hidden, "run", true)).toEqual([]);
  });

  test("does not expose an unavailable Database placeholder", () => {
    expect([...SIDEBAR_ACTIVITY_ITEM_IDS]).not.toContain("database");
  });

  test("keeps bottom activity items ordered after the primary views", () => {
    expect([...SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS]).toEqual([
      "run",
      "terminal",
      "diagnostics",
      "gitLog",
      "settings",
    ]);
  });

  test("drops the removed Maven item from persisted left sidebar order", () => {
    expect(normalizeItemOrder(["maven", "run"], SIDEBAR_ACTIVITY_ITEM_IDS)).toEqual([
      "run",
      "files",
      "git",
      "search",
      "terminal",
      "diagnostics",
      "gitLog",
      "settings",
    ]);
  });
});
