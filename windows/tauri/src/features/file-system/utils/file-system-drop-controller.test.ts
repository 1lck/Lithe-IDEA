import { describe, expect, test } from "bun:test";
import { dispatchTerminalPathInsert, isTerminalDropTarget } from "./file-system-drop-controller";

/**
 * Minimal stand-in for DOM ancestors so the selector walk is deterministic
 * without mounting a real terminal. Cast at the boundary because the production
 * API takes an `Element` and only ever calls `closest`/`dispatchEvent` on it.
 */
function fakeTarget(attributes: string[]): {
  element: Element;
  dispatched: Event[];
} {
  const dispatched: Event[] = [];
  const terminal = {
    dispatchEvent: (event: Event) => {
      dispatched.push(event);
      return true;
    },
  };
  const element = {
    closest: (selector: string) =>
      selector === "[data-terminal-drop-target]" && attributes.includes("terminal") ? terminal : null,
  } as unknown as Element;
  return { element, dispatched };
}

describe("isTerminalDropTarget", () => {
  test("recognizes a drop inside the terminal", () => {
    expect(isTerminalDropTarget(fakeTarget(["terminal"]).element)).toBe(true);
  });

  // The explorer checks this before its pane branch, so a non-terminal pane must
  // not be treated as a terminal.
  test("rejects a pane that is not a terminal", () => {
    expect(isTerminalDropTarget(fakeTarget(["pane"]).element)).toBe(false);
  });

  test("rejects a missing element", () => {
    expect(isTerminalDropTarget(null)).toBe(false);
  });
});

describe("dispatchTerminalPathInsert", () => {
  test("forwards the formatted text to the terminal", () => {
    const target = fakeTarget(["terminal"]);
    expect(dispatchTerminalPathInsert(target.element, "a.ts ")).toBe(true);
    expect(target.dispatched).toHaveLength(1);
    expect((target.dispatched[0] as CustomEvent<{ text: string }>).detail.text).toBe("a.ts ");
  });

  test("does nothing outside a terminal", () => {
    const target = fakeTarget(["pane"]);
    expect(dispatchTerminalPathInsert(target.element, "a.ts")).toBe(false);
    expect(target.dispatched).toHaveLength(0);
  });

  test("does not dispatch empty text", () => {
    const target = fakeTarget(["terminal"]);
    expect(dispatchTerminalPathInsert(target.element, "")).toBe(false);
    expect(target.dispatched).toHaveLength(0);
  });
});
