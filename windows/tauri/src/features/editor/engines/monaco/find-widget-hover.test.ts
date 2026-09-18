import { afterAll, describe, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { suppressFindWidgetCloseButtonHover } from "./find-widget-hover";

const restoreDom = installHappyDom();

afterAll(() => {
  restoreDom();
});

describe("Monaco find widget close hover", () => {
  test("blocks only the close button mouseover used by Monaco's delayed hover", () => {
    const container = document.createElement("div");
    const findWidget = document.createElement("div");
    const closeButton = document.createElement("div");
    const nextButton = document.createElement("div");
    findWidget.className = "find-widget";
    closeButton.className = "button codicon codicon-widget-close";
    closeButton.setAttribute("role", "button");
    closeButton.setAttribute("aria-label", "Close (Escape)");
    nextButton.className = "button codicon codicon-find-next-match";
    nextButton.setAttribute("role", "button");
    findWidget.append(closeButton, nextButton);
    container.append(findWidget);
    document.body.append(container);

    let closeHoverCount = 0;
    let nextHoverCount = 0;
    closeButton.addEventListener("mouseover", () => {
      closeHoverCount += 1;
    });
    nextButton.addEventListener("mouseover", () => {
      nextHoverCount += 1;
    });

    const dispose = suppressFindWidgetCloseButtonHover(container);
    try {
      closeButton.dispatchEvent(new Event("mouseover", { bubbles: true }));
      nextButton.dispatchEvent(new Event("mouseover", { bubbles: true }));

      expect(closeHoverCount).toBe(0);
      expect(nextHoverCount).toBe(1);
      expect(closeButton.getAttribute("aria-label")).toBe("Close (Escape)");

      dispose();
      closeButton.dispatchEvent(new Event("mouseover", { bubbles: true }));
      expect(closeHoverCount).toBe(1);
    } finally {
      dispose();
      container.remove();
    }
  });
});
