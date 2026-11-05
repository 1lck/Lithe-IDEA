import { describe, expect, test } from "bun:test";
import {
  actionChoices, actionLane, actionMarkers, normalizeEditorActions, type EditorAction,
} from "./plugin-editor-action-rules";

function action(overrides: Partial<EditorAction>): EditorAction {
  return { id: "a", line: 1, endLine: 1, title: "Run", icon: "run", alternatives: [], ...overrides };
}

describe("plugin editor actions", () => {
  test("navigation icons use the left lane and everything else the run lane", () => {
    expect(actionLane("navigate-super")).toBe("left");
    expect(actionLane("navigate-implementations")).toBe("left");
    expect(actionLane("run")).toBe("right");
    expect(actionLane("test-failed")).toBe("right");
  });

  test("keep well-formed actions inside the document and tolerate a missing alternatives list", () => {
    const actions = normalizeEditorActions([
      { id: "a", line: 2, endLine: 9, title: "Run", icon: "run" },
      { id: "b", line: 40, endLine: 40, title: "Late", icon: "run" },
      { id: "c", line: 3, title: "Bad icon", icon: "Run Now" },
      { id: "d", line: 3, title: 7, icon: "run" },
      { id: "e", line: 4, endLine: 99, title: "Test", icon: "test", alternatives: [
        { id: "debug", title: "Debug", icon: "debug" },
        { id: "broken", title: "No icon" },
      ] },
    ], 10);

    expect(actions.map(item => item.id)).toEqual(["a", "e"]);
    expect(actions[0]).toMatchObject({ endLine: 9, alternatives: [] });
    expect(actions[1].endLine).toBe(10);
    expect(actions[1].alternatives).toEqual([{ id: "debug", title: "Debug", icon: "debug" }]);
    expect(normalizeEditorActions({ actions: [] }, 10)).toEqual([]);
  });

  test("accept at most four alternatives", () => {
    const alternatives = Array.from({ length: 6 }, (_, index) => ({ id: `alt${index}`, title: "Alt", icon: "run" }));
    expect(normalizeEditorActions([{ id: "a", line: 1, title: "Run", icon: "run", alternatives }], 3)[0].alternatives)
      .toHaveLength(4);
  });

  test("draw one marker per line and lane, led by the first action", () => {
    const markers = actionMarkers([
      action({ id: "run", line: 3, title: "Run test", icon: "test-passed" }),
      action({ id: "preview", line: 3, title: "Preview", icon: "run" }),
      action({ id: "super", line: 3, title: "Go to super", icon: "navigate-super" }),
      action({ id: "first", line: 1, title: "Run main", icon: "run" }),
    ]);

    expect(markers).toEqual([
      { line: 1, lane: "right", icon: "run", title: "Run main" },
      { line: 3, lane: "right", icon: "test-passed", title: "Run test" },
      { line: 3, lane: "left", icon: "navigate-super", title: "Go to super" },
    ]);
  });

  test("a marker's menu lists its lane's actions with each action's alternatives after it", () => {
    const actions = [
      action({ id: "run", line: 3, title: "Run test", icon: "test", alternatives: [
        { id: "debug", title: "Debug test", icon: "debug" },
      ] }),
      action({ id: "preview", line: 3, title: "Preview", icon: "run" }),
      action({ id: "super", line: 3, title: "Go to super", icon: "navigate-super" }),
      action({ id: "other", line: 4, title: "Elsewhere", icon: "run" }),
    ];

    expect(actionChoices(actions, 3, "right")).toEqual([
      { key: "run", title: "Run test", action: "run" },
      { key: "run.debug", title: "Debug test", action: "run", alternative: "debug" },
      { key: "preview", title: "Preview", action: "preview" },
    ]);
    expect(actionChoices(actions, 3, "left").map(item => item.action)).toEqual(["super"]);
    expect(actionChoices(actions, 9, "right")).toEqual([]);
  });
});
