import { describe, expect, test } from "bun:test";
import { closeFindWidget, type FindWidgetState } from "./find-widget-lifecycle";

type FindWidgetEditor = Parameters<typeof closeFindWidget>[0];

function createEditor(isRevealed: boolean | null) {
  const contributionIds: string[] = [];
  const changes: { next: { isRevealed: boolean }; moveCursor: boolean }[] = [];
  const state: FindWidgetState = {
    isRevealed: isRevealed === true,
    change(next, moveCursor) {
      changes.push({ next, moveCursor });
    },
  };
  const editor = {
    getContribution(id: string) {
      contributionIds.push(id);
      return isRevealed === null ? null : { getState: () => state };
    },
  } as unknown as FindWidgetEditor;

  return { editor, contributionIds, changes };
}

describe("Monaco find widget lifecycle", () => {
  test("closes a revealed find widget and keeps its query intact", () => {
    const { editor, contributionIds, changes } = createEditor(true);

    expect(closeFindWidget(editor)).toBe(true);
    expect(contributionIds).toEqual(["editor.contrib.findController"]);
    expect(changes).toEqual([{ next: { isRevealed: false }, moveCursor: false }]);
  });

  test("leaves an already closed find widget untouched", () => {
    const { editor, changes } = createEditor(false);

    expect(closeFindWidget(editor)).toBe(false);
    expect(changes).toEqual([]);
  });

  test("ignores editors without a find controller", () => {
    const { editor, changes } = createEditor(null);

    expect(closeFindWidget(editor)).toBe(false);
    expect(changes).toEqual([]);
  });
});
