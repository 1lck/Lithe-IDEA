import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { isEditorKeyboardTarget } from "./editor-keyboard-target";

const OriginalHTMLElement = globalThis.HTMLElement;

class TestHTMLElement {
  constructor(
    private readonly selectors: Set<string>,
    readonly isContentEditable = false,
  ) {}

  matches(selector: string) {
    if (selector === "input, textarea") {
      return this.selectors.has("input") || this.selectors.has("textarea");
    }
    return this.selectors.has(selector);
  }

  closest(selector: string) {
    return this.selectors.has(selector) ? this : null;
  }
}

beforeAll(() => {
  globalThis.HTMLElement = TestHTMLElement as unknown as typeof HTMLElement;
});

afterAll(() => {
  globalThis.HTMLElement = OriginalHTMLElement;
});

describe("editor keyboard target", () => {
  test("treats Monaco's main input area as the editor", () => {
    const target = new TestHTMLElement(
      new Set(["textarea", "textarea.inputarea", ".monaco-editor"]),
    );

    expect(isEditorKeyboardTarget(target as unknown as HTMLElement)).toBe(true);
  });

  test("does not treat the Monaco find input as the editor", () => {
    const target = new TestHTMLElement(new Set(["input", ".monaco-editor"]));

    expect(isEditorKeyboardTarget(target as unknown as HTMLElement)).toBe(false);
  });

  test("does not treat content-editable controls inside Monaco as the editor", () => {
    const target = new TestHTMLElement(new Set([".monaco-editor"]), true);

    expect(isEditorKeyboardTarget(target as unknown as HTMLElement)).toBe(false);
  });
});
