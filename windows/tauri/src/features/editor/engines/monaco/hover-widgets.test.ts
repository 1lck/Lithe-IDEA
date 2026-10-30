import { afterAll, describe, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { clampMonacoHoverWidgets } from "./hover-widgets";

const restoreDom = installHappyDom();

afterAll(() => {
  restoreDom();
});

const HOVER_MAX_WIDTH_PROPERTY = "--lithe-monaco-hover-max-width";

describe("Monaco hover clamp", () => {
  test("writes nothing to the editor when no hover is shown", () => {
    const container = document.createElement("div");
    container.innerHTML = '<div class="view-lines"></div>';
    const before = container.outerHTML;

    clampMonacoHoverWidgets(container);

    expect(container.outerHTML).toBe(before);
    expect(container.style.getPropertyValue(HOVER_MAX_WIDTH_PROPERTY)).toBe("");
  });

  test("sets the width limit on the hover widget instead of the editor container", () => {
    const container = document.createElement("div");
    const widget = document.createElement("div");
    widget.setAttribute("widgetid", "editor.contrib.resizableContentHoverWidget");
    widget.innerHTML = '<div class="monaco-hover"><div class="monaco-hover-content"></div></div>';
    container.appendChild(widget);

    clampMonacoHoverWidgets(container);

    expect(container.style.getPropertyValue(HOVER_MAX_WIDTH_PROPERTY)).toBe("");
    expect(widget.style.getPropertyValue(HOVER_MAX_WIDTH_PROPERTY)).toMatch(/^\d+px$/);
    expect(widget.style.maxWidth).toBe(widget.style.getPropertyValue(HOVER_MAX_WIDTH_PROPERTY));
  });
});
