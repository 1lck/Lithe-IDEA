import { createElement, Fragment } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "bun:test";
import type { HighlightToken } from "@/features/editor/types/wasm-parser/wasm-parser.types";
import { getUnifiedLineGutterLabel, renderDiffLineContent } from "./git-diff-line";

function renderContent(
  content: string,
  showWhitespace: boolean,
  tokens?: HighlightToken[],
): string {
  return renderToStaticMarkup(
    createElement(Fragment, null, renderDiffLineContent(content, tokens, showWhitespace)),
  );
}

function token(start: number, end: number, type = "token-tag"): HighlightToken {
  return {
    type,
    startIndex: start,
    endIndex: end,
    startPosition: { row: 0, column: start },
    endPosition: { row: 0, column: end },
  };
}

describe("diff line whitespace rendering", () => {
  test("shows carriage returns when whitespace is enabled", () => {
    expect(renderContent("same\r", true)).toContain("␍");
    expect(renderContent("same\r", false)).not.toContain("␍");
  });
});

describe("unified diff line numbers", () => {
  test("shows the original line number for a deleted line", () => {
    expect(
      getUnifiedLineGutterLabel({
        line_type: "removed",
        content: "deleted line",
        old_line_number: 16,
      }),
    ).toBe(16);
  });
});

describe("diff line syntax token rendering", () => {
  test("does not duplicate characters when highlight tokens overlap", () => {
    const content = "      <groupId>com.whds</groupId>";
    const html = renderContent(content, false, [
      // Nested markup often emits a wide parent capture plus inner tag captures.
      token(0, content.length, "token-string"),
      token(6, 15, "token-tag"),
      token(6, 7, "token-punctuation"),
      token(7, 14, "token-tag"),
      token(14, 15, "token-punctuation"),
    ]);
    const visibleText = html
      .replace(/<[^>]+>/g, "")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">");

    expect(visibleText).not.toContain("groupIdgroupId");
    expect(visibleText).toBe(content);
  });

  test("keeps pom.xml-like markup text intact with nested token ranges", () => {
    const content = "    <dependency>";
    const html = renderContent(content, false, [
      token(0, content.length, "token-string"),
      token(4, 5, "token-punctuation"),
      token(5, 15, "token-tag"),
      token(15, 16, "token-punctuation"),
    ]);
    const visibleText = html
      .replace(/<[^>]+>/g, "")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">");

    expect(visibleText).toBe(content);
    expect(html).toContain("token-tag");
    expect(html).toContain("token-punctuation");
  });
});
