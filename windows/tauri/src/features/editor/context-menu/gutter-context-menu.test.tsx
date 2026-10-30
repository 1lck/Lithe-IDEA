import { describe, expect, test } from "bun:test";
import { buildGutterContextMenuItems } from "./gutter-context-menu";

const t = (key: string) => key;

describe("gutter context menu", () => {
  test("stays empty when no line action is available", () => {
    // A non-repository or untracked file gets no menu rather than dead entries.
    expect(buildGutterContextMenuItems({ t })).toEqual([]);
  });

  test("offers annotate when the file can be annotated", () => {
    const items = buildGutterContextMenuItems({ t, onToggleBlame: () => {} });

    expect(items.map((item) => item.id)).toEqual(["toggle-blame"]);
    expect(items[0]?.label).toBe("git.blame.annotate");
  });

  test("labels the toggle by the current annotation state", () => {
    const items = buildGutterContextMenuItems({
      t,
      onToggleBlame: () => {},
      blameVisible: true,
    });

    expect(items[0]?.label).toBe("git.blame.hide");
  });

  test("keeps line history beside the annotate toggle", () => {
    const items = buildGutterContextMenuItems({
      t,
      onToggleBlame: () => {},
      onLineHistory: () => {},
    });

    expect(items.map((item) => item.id)).toEqual(["toggle-blame", "line-history"]);
  });
});
