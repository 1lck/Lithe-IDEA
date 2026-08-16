import { describe, expect, test } from "bun:test";
import { SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS } from "@/features/layout/config/item-order";
import { defaultKeymaps } from "./default-keymaps";

describe("Git Log workbench entry points", () => {
  test("binds the IntelliJ-compatible Alt+9 shortcut", () => {
    expect(defaultKeymaps).toContainEqual({
      key: "alt+9",
      command: "workbench.toggleGitLog",
      source: "default",
    });
  });

  test("places Git Log on the bottom activity rail above Settings", () => {
    expect(SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS.indexOf("run")).toBeLessThan(
      SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS.indexOf("gitLog"),
    );
    expect(SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS.indexOf("gitLog")).toBeLessThan(
      SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS.indexOf("settings"),
    );
  });
});
