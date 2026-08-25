import { describe, expect, test } from "bun:test";
import {
  FOOTER_TRAILING_ITEM_IDS,
  SIDEBAR_ACTIVITY_ITEM_IDS,
  SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS,
  normalizeItemOrder,
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
  test("does not expose an unavailable Database placeholder", () => {
    expect([...SIDEBAR_ACTIVITY_ITEM_IDS]).not.toContain("database");
  });

  test("places Run, Terminal, Diagnostics, Git Log, then Settings", () => {
    expect([...SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS]).toEqual([
      "run",
      "terminal",
      "diagnostics",
      "gitLog",
      "settings",
    ]);
  });
});
