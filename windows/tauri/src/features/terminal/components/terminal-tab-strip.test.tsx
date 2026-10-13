import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterAll, describe, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { HorizontalTerminalTabStrip } from "./terminal-tab-strip";

const restoreDom = installHappyDom();
afterAll(restoreDom);

const tabs = (prefix: string, count: number) =>
  Array.from({ length: count }, (_, index) =>
    createElement("span", { key: index, "data-tab": `${prefix}-${index}` }),
  );

function renderStrip(pinnedCount: number, regularCount: number) {
  const markup = renderToStaticMarkup(
    createElement(HorizontalTerminalTabStrip, {
      pinnedTabs: pinnedCount > 0 ? tabs("pinned", pinnedCount) : null,
      regularTabs: tabs("regular", regularCount),
      actions: createElement("button", { "data-new-terminal": true }),
      onWheel: () => {},
    }),
  );
  const container = document.createElement("div");
  container.innerHTML = markup;
  const root = container.firstElementChild!;
  const scrollArea = root.querySelector("[data-tab-container]")!;
  const actions = root.querySelector("[data-tab-strip-actions]")!;
  return { root, scrollArea, actions };
}

// Regression: with enough pinned tabs, a non-shrinking pinned group sat beside the scroll area
// inside an overflow-hidden wrapper and clipped the new-terminal actions. Real widths are not
// measurable here, so the test protects the structure that guarantees the actions stay visible.
describe("horizontal terminal tab strip", () => {
  test.each([
    ["many pinned tabs", 12, 0],
    ["many regular tabs", 0, 12],
    ["pinned and regular tabs", 8, 8],
  ])(
    "keeps every tab in the scroll area and the actions outside it with %s",
    (_, pinned, regular) => {
      const { root, scrollArea, actions } = renderStrip(pinned, regular);

      expect(scrollArea.querySelectorAll("[data-tab]")).toHaveLength(pinned + regular);
      expect(scrollArea.className).toContain("overflow-x-auto");
      expect(scrollArea.className).toContain("min-w-0");
      expect(scrollArea.querySelector("[data-new-terminal]")).toBeNull();
      expect(actions.querySelector("[data-new-terminal]")).not.toBeNull();
      expect(actions.className).toContain("shrink-0");
      // The actions are a direct sibling of the scroll area, never nested in a clipped tab group.
      expect(actions.parentElement === root).toBe(true);
    },
  );

  test("keeps pinned tabs ahead of regular tabs inside the shared scroll area", () => {
    const { scrollArea } = renderStrip(2, 2);

    const order = [...scrollArea.querySelectorAll("[data-tab]")].map((tab) =>
      tab.getAttribute("data-tab"),
    );
    expect(order).toEqual(["pinned-0", "pinned-1", "regular-0", "regular-1"]);
    expect(scrollArea.querySelector("[data-pinned-tabs]")?.className).toContain("shrink-0");
  });
});
