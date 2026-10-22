import { describe, expect, test } from "bun:test";
import {
  AGENT_DROP_TARGET_SELECTOR,
  AGENT_FILE_DROP_EVENT,
  AGENT_FILE_DROP_HOVER_EVENT,
  dispatchAgentDropHover,
  dispatchDroppedPathsToAgent,
  dispatchTerminalPathInsert,
  getExternalFileDropRoute,
  isTerminalDropTarget,
} from "./file-system-drop-controller";

/** Element stand-in: `closest` matches the selectors listed as its ancestors. */
function element(ancestors: string[]) {
  const dispatched: CustomEvent[] = [];
  const node = {
    dispatched,
    dispatchEvent(event: Event) {
      dispatched.push(event as CustomEvent);
      return true;
    },
    closest(selector: string) {
      const parts = selector.split(",");
      return parts.some((part) => ancestors.includes(part)) ? node : null;
    },
  };
  return node as typeof node & Pick<Element, "closest">;
}

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
  test("forwards the absolute paths to the terminal", () => {
    const target = fakeTarget(["terminal"]);
    expect(dispatchTerminalPathInsert(target.element, ["C:\\work\\proj\\a.ts"])).toBe(true);
    expect(target.dispatched).toHaveLength(1);
    expect((target.dispatched[0] as CustomEvent<{ paths: string[] }>).detail.paths).toEqual([
      "C:\\work\\proj\\a.ts",
    ]);
  });

  test("does nothing outside a terminal", () => {
    const target = fakeTarget(["pane"]);
    expect(dispatchTerminalPathInsert(target.element, ["C:\\work\\proj\\a.ts"])).toBe(false);
    expect(target.dispatched).toHaveLength(0);
  });

  test("does not dispatch an empty path list", () => {
    const target = fakeTarget(["terminal"]);
    expect(dispatchTerminalPathInsert(target.element, [])).toBe(false);
    expect(target.dispatched).toHaveLength(0);
  });
});

describe("external file drop routing", () => {
  test("drops over the Agent composer route to it even inside the sidebar scope", () => {
    const composer = element([AGENT_DROP_TARGET_SELECTOR, "[data-external-file-drop-scope]"]);
    expect(getExternalFileDropRoute(composer)).toBe("agent");
  });

  test("other surfaces keep their existing routes", () => {
    expect(getExternalFileDropRoute(element(["[data-terminal-drop-target]"]))).toBe("terminal");
    expect(getExternalFileDropRoute(element(["[data-external-file-drop-scope]"]))).toBe("local");
    expect(getExternalFileDropRoute(element([]))).toBe("global");
    expect(getExternalFileDropRoute(null)).toBe("global");
  });

  test("hands parsed absolute paths to the composer that owns the drop point", () => {
    const composer = element([AGENT_DROP_TARGET_SELECTOR]);
    const delivered = dispatchDroppedPathsToAgent(composer, [
      "C:\\work\\demo project\\README.md",
      "file:///C:/work/demo%20project/src/main.ts",
      "relative/ignored.txt",
    ]);

    expect(delivered).toBe(true);
    expect(composer.dispatched.map((event) => event.type)).toEqual([AGENT_FILE_DROP_EVENT]);
    expect(composer.dispatched[0]?.detail).toEqual({
      paths: ["C:\\work\\demo project\\README.md", "C:/work/demo project/src/main.ts"],
    });
  });

  test("dispatches nothing outside the composer or without usable paths", () => {
    const elsewhere = element([]);
    expect(dispatchDroppedPathsToAgent(elsewhere, ["C:\\work\\README.md"])).toBe(false);
    const composer = element([AGENT_DROP_TARGET_SELECTOR]);
    expect(dispatchDroppedPathsToAgent(composer, ["relative.txt"])).toBe(false);
    expect(composer.dispatched).toHaveLength(0);
  });

  test("reports hover to the composer so the drop point can highlight", () => {
    const composer = element([AGENT_DROP_TARGET_SELECTOR]);
    expect(dispatchAgentDropHover(composer, true)).toBe(true);
    expect(dispatchAgentDropHover(composer, false)).toBe(true);
    expect(composer.dispatched.map((event) => [event.type, event.detail])).toEqual([
      [AGENT_FILE_DROP_HOVER_EVENT, { active: true }],
      [AGENT_FILE_DROP_HOVER_EVENT, { active: false }],
    ]);
    expect(dispatchAgentDropHover(element([]), true)).toBe(false);
  });
});
