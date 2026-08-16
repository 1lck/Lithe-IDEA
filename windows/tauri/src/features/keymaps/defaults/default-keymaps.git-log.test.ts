import { describe, expect, test } from "bun:test";
import { FOOTER_LEADING_ITEM_IDS, normalizeItemOrder } from "@/features/layout/config/item-order";
import { defaultKeymaps } from "./default-keymaps";

describe("Git Log workbench entry points", () => {
  test("binds the IntelliJ-compatible Alt+9 shortcut", () => {
    expect(defaultKeymaps).toContainEqual({
      key: "alt+9",
      command: "workbench.toggleGitLog",
      source: "default",
    });
  });

  test("adds the Git button to an existing persisted footer order", () => {
    expect(
      normalizeItemOrder(["branch", "terminal", "diagnostics"], FOOTER_LEADING_ITEM_IDS),
    ).toEqual(["branch", "terminal", "diagnostics", "gitLog"]);
  });
});
