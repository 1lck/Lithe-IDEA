import { describe, expect, test } from "bun:test";
import { buildEditorContextMenuItems } from "./editor-context-menu-items";

const t = (key: string) => key;
const base = { hasSelection: false, modifierKey: "Ctrl", altKey: "Alt", t };

describe("editor context menu Git submenu", () => {
  test("omits the submenu when no Git action applies", () => {
    const items = buildEditorContextMenuItems(base);

    expect(items.some((item) => item.id === "git")).toBe(false);
  });

  test("groups annotate, commit actions and line history under Git", () => {
    const items = buildEditorContextMenuItems({
      ...base,
      onToggleBlame: () => {},
      blameVisible: true,
      onBlameShowDiff: () => {},
      onBlameCopyRevision: () => {},
      onLineHistory: () => {},
    });

    const git = items.find((item) => item.id === "git");
    expect(git?.label).toBe("git.contextMenu.submenu");
    expect(git?.children?.map((child) => child.id)).toEqual([
      "git-toggle-blame",
      "git-blame-show-diff",
      "git-blame-copy-revision",
      "line-history",
    ]);
    // Line history moved inside the submenu instead of sitting at top level.
    expect(items.some((item) => item.id === "line-history")).toBe(false);
  });

  test("keeps line history reachable while annotations are off", () => {
    const items = buildEditorContextMenuItems({
      ...base,
      onToggleBlame: () => {},
      onLineHistory: () => {},
    });

    expect(items.find((item) => item.id === "git")?.children?.map((child) => child.id)).toEqual([
      "git-toggle-blame",
      "line-history",
    ]);
  });
});
