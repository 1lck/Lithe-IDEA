import { describe, expect, test } from "bun:test";
import { EDITOR_CONSTANTS } from "../config/constants";
import { buildEditorViewLayout } from "./view-layout";

const CHAR_WIDTH = 8;

function measureText(text: string): number {
  let width = 0;
  for (const char of text) {
    if (char !== "\r") width += CHAR_WIDTH;
  }
  return width;
}

describe("editorPointToModelPosition", () => {
  test("places the caret after the last visible character when clicking the line end", () => {
    const line = "    private int code;";
    const layout = buildEditorViewLayout({
      lines: [line],
      lineHeight: 20,
      wordWrap: false,
      contentWidth: 800,
      measureText,
    });

    const endX = EDITOR_CONSTANTS.EDITOR_PADDING_LEFT + measureText(line);
    const atEnd = layout.editorPointToModelPosition(endX, EDITOR_CONSTANTS.EDITOR_PADDING_TOP + 2);
    const pastEnd = layout.editorPointToModelPosition(
      endX + CHAR_WIDTH * 4,
      EDITOR_CONSTANTS.EDITOR_PADDING_TOP + 2,
    );
    const rightHalfOfSemicolon = layout.editorPointToModelPosition(
      endX - CHAR_WIDTH / 4,
      EDITOR_CONSTANTS.EDITOR_PADDING_TOP + 2,
    );

    expect(atEnd.column).toBe(line.length);
    expect(pastEnd.column).toBe(line.length);
    expect(rightHalfOfSemicolon.column).toBe(line.length);
  });

  test("does not treat a trailing carriage return as a visible column", () => {
    const visualLine = "    private int code;";
    const layout = buildEditorViewLayout({
      lines: [`${visualLine}\r`],
      lineHeight: 20,
      wordWrap: false,
      contentWidth: 800,
      measureText,
    });

    const endX = EDITOR_CONSTANTS.EDITOR_PADDING_LEFT + measureText(visualLine);
    const pastEnd = layout.editorPointToModelPosition(
      endX + CHAR_WIDTH,
      EDITOR_CONSTANTS.EDITOR_PADDING_TOP + 2,
    );

    expect(pastEnd.column).toBe(visualLine.length);
  });
});
