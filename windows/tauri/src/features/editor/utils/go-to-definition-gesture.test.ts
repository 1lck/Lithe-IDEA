import { describe, expect, test } from "bun:test";
import { isEditorGoToDefinitionModifierClick } from "./go-to-definition-gesture";

describe("IDEA-style go to definition click", () => {
  test("accepts unmodified Ctrl or Cmd left clicks", () => {
    expect(
      isEditorGoToDefinitionModifierClick({ leftButton: true, ctrlKey: true }),
    ).toBe(true);
    expect(
      isEditorGoToDefinitionModifierClick({ leftButton: true, metaKey: true }),
    ).toBe(true);
  });

  test("ignores right clicks and extra modifiers", () => {
    expect(isEditorGoToDefinitionModifierClick({ leftButton: false, ctrlKey: true })).toBe(false);
    expect(
      isEditorGoToDefinitionModifierClick({
        leftButton: true,
        ctrlKey: true,
        shiftKey: true,
      }),
    ).toBe(false);
    expect(
      isEditorGoToDefinitionModifierClick({
        leftButton: true,
        ctrlKey: true,
        altKey: true,
      }),
    ).toBe(false);
  });
});
