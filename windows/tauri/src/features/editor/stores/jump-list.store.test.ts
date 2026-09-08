import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { useJumpListStore, type JumpListEntry } from "./jump-list.store";

function cursorEntry(line: number, column: number): Omit<JumpListEntry, "timestamp"> {
  return {
    bufferId: "buffer-a",
    filePath: "C:/workspace/a.ts",
    line,
    column,
    offset: line * 100 + column,
    scrollTop: line * 10,
    scrollLeft: column,
  };
}

function clearJumpList() {
  useJumpListStore.getState().actions.clear();
}

beforeEach(clearJumpList);
afterEach(clearJumpList);

describe("jump list cursor history", () => {
  test("keeps distinct positions in the same file, including their columns", () => {
    const actions = useJumpListStore.getState().actions;

    actions.recordCursorEntry(cursorEntry(9, 19));
    actions.recordCursorEntry(cursorEntry(9, 4));
    actions.recordCursorEntry(cursorEntry(19, 4));

    const positions = useJumpListStore
      .getState()
      .entries.map(({ line, column, offset }) => ({ line, column, offset }));
    expect(positions).toEqual([
      { line: 9, column: 19, offset: 919 },
      { line: 9, column: 4, offset: 904 },
      { line: 19, column: 4, offset: 1904 },
    ]);
  });

  test("preserves an exact cursor entry before a nearby explicit navigation entry", () => {
    const actions = useJumpListStore.getState().actions;
    const cursorPosition = cursorEntry(10, 5);
    const explicitNavigationPosition = cursorEntry(10, 20);
    const destination = cursorEntry(30, 4);

    actions.recordCursorEntry(cursorPosition);
    actions.pushEntry(explicitNavigationPosition);

    expect(
      useJumpListStore
        .getState()
        .entries.map(({ line, column, offset }) => ({ line, column, offset })),
    ).toEqual([
      { line: 10, column: 5, offset: 1005 },
      { line: 10, column: 20, offset: 1020 },
    ]);

    expect(actions.goBack(destination)).toMatchObject(explicitNavigationPosition);
    expect(actions.goBack()).toMatchObject(cursorPosition);
    expect(actions.goForward()).toMatchObject(explicitNavigationPosition);
    expect(actions.goForward()).toMatchObject(destination);
  });

  test("navigates back and forward across normal cursor positions", () => {
    const actions = useJumpListStore.getState().actions;
    const first = cursorEntry(9, 19);
    const second = cursorEntry(19, 4);
    const third = cursorEntry(29, 11);

    actions.recordCursorEntry(first);
    actions.recordCursorEntry(second);

    expect(actions.goBack(third)).toMatchObject(second);
    expect(actions.goBack()).toMatchObject(first);
    expect(actions.goForward()).toMatchObject(second);
    expect(actions.goForward()).toMatchObject(third);
  });

  test("drops forward cursor positions after a new movement", () => {
    const actions = useJumpListStore.getState().actions;
    const first = cursorEntry(9, 19);
    const second = cursorEntry(19, 4);
    const third = cursorEntry(29, 11);

    actions.recordCursorEntry(first);
    actions.recordCursorEntry(second);
    expect(actions.goBack(third)).toMatchObject(second);
    expect(actions.goBack()).toMatchObject(first);

    actions.recordCursorEntry(first);

    expect(actions.goForward()).toBeNull();
  });
});
