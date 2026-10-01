import { describe, expect, test } from "bun:test";
import {
  AGENT_DROP_TARGET_SELECTOR,
  AGENT_FILE_DROP_EVENT,
  dispatchDroppedPathsToAgent,
  getExternalFileDropRoute,
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
});
