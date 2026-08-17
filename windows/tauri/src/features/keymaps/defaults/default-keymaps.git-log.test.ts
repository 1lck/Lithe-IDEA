import { describe, expect, test } from "bun:test";
import { SIDEBAR_BOTTOM_ACTIVITY_ITEM_IDS } from "@/features/layout/config/item-order";
import { defaultKeymaps } from "./default-keymaps";

describe("IDEA-style definition shortcuts", () => {
  test("binds Ctrl/Cmd+B to find references while the editor is focused", () => {
    expect(defaultKeymaps).toContainEqual({
      key: "cmd+b",
      command: "editor.goToReferences",
      source: "default",
      when: "editorFocus",
    });
  });

  test("keeps the activity sidebar toggle off the editor Ctrl/Cmd+B shortcut", () => {
    expect(defaultKeymaps).toContainEqual({
      key: "cmd+b",
      command: "workbench.toggleActivitySidebar",
      source: "default",
      when: "!editorFocus",
    });
  });
});

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
