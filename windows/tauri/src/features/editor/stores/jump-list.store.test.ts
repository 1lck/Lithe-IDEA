import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { useJumpListStore, type JumpListEntry } from "./jump-list.store";

function cursorEntry(
  line: number,
  column: number,
  paneId?: string,
): Omit<JumpListEntry, "timestamp"> {
  return {
    bufferId: "buffer-a",
    filePath: "C:/workspace/a.ts",
    paneId,
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

  test("keeps nearby explicit entries distinct in the same pane", () => {
    const actions = useJumpListStore.getState().actions;
    const paneId = "left-pane";

    actions.pushEntry(cursorEntry(10, 5, paneId));
    actions.pushEntry(cursorEntry(10, 20, paneId));

    expect(
      useJumpListStore
        .getState()
        .entries.map(({ line, column, paneId: entryPaneId }) => ({
          line,
          column,
          paneId: entryPaneId,
        })),
    ).toEqual([
      { line: 10, column: 5, paneId },
      { line: 10, column: 20, paneId },
    ]);
  });

  test("navigates chronologically across panes and preserves each destination pane", () => {
    const actions = useJumpListStore.getState().actions;
    const leftPaneId = "left-pane";
    const rightPaneId = "right-pane";

    actions.recordCursorEntry(cursorEntry(9, 1, leftPaneId));
    actions.recordCursorEntry(cursorEntry(19, 1, leftPaneId));
    actions.recordCursorEntry(cursorEntry(29, 1, rightPaneId));
    actions.recordCursorEntry(cursorEntry(39, 1, rightPaneId));

    expect(actions.goBack(cursorEntry(49, 1, rightPaneId))).toMatchObject({
      line: 39,
      paneId: rightPaneId,
    });
    expect(actions.goBack()).toMatchObject({ line: 29, paneId: rightPaneId });
    expect(actions.goBack()).toMatchObject({ line: 19, paneId: leftPaneId });
    expect(actions.goBack()).toMatchObject({ line: 9, paneId: leftPaneId });

    expect(actions.goForward()).toMatchObject({ line: 19, paneId: leftPaneId });
    expect(actions.goForward()).toMatchObject({ line: 29, paneId: rightPaneId });
    expect(actions.goForward()).toMatchObject({ line: 39, paneId: rightPaneId });
    expect(actions.goForward()).toMatchObject({ line: 49, paneId: rightPaneId });
  });
});
