import { describe, expect, test } from "bun:test";
import { matchKeybinding } from "./matcher";

function keyboardEvent(overrides: Partial<KeyboardEvent>): KeyboardEvent {
  return {
    altKey: false,
    code: "",
    ctrlKey: false,
    key: "",
    metaKey: false,
    shiftKey: false,
    ...overrides,
  } as KeyboardEvent;
}

describe("keymap matcher", () => {
  test("matches Ctrl+Shift+F by physical key while an IME changes event.key", () => {
    const event = keyboardEvent({
      code: "KeyF",
      ctrlKey: true,
      key: "ㄈ",
      shiftKey: true,
    });

    expect(matchKeybinding(event, "cmd+shift+f").matched).toBe(true);
  });

  test("does not treat a modifier-only key as global search", () => {
    const event = keyboardEvent({ code: "ShiftLeft", key: "Shift", shiftKey: true });

    expect(matchKeybinding(event, "cmd+shift+f").matched).toBe(false);
  });
});
