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

    // IDEA names the same action "Close Annotations" while annotating.
    expect(items[0]?.label).toBe("git.blame.hide");
  });

  test("adds the commit actions only while annotations are shown", () => {
    const handlers = {
      t,
      onToggleBlame: () => {},
      onShowDiff: () => {},
      onCopyRevision: () => {},
    };

    // Show Diff and Copy Revision act on the annotated commit, so they cannot
    // appear before the annotation exists.
    expect(buildGutterContextMenuItems(handlers).map((item) => item.id)).toEqual(["toggle-blame"]);
    expect(
      buildGutterContextMenuItems({ ...handlers, blameVisible: true }).map((item) => item.id),
    ).toEqual(["toggle-blame", "blame-show-diff", "blame-copy-revision"]);
  });

  test("leaves line history to the editor menu", () => {
    const items = buildGutterContextMenuItems({
      t,
      onToggleBlame: () => {},
      blameVisible: true,
      onShowDiff: () => {},
      onCopyRevision: () => {},
    });

    expect(items.some((item) => item.id === "line-history")).toBe(false);
  });
});
