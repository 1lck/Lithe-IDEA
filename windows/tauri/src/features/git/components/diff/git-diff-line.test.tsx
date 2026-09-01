import { createElement, Fragment } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "bun:test";
import { getUnifiedLineGutterLabel, renderDiffLineContent } from "./git-diff-line";

function renderContent(content: string, showWhitespace: boolean): string {
  return renderToStaticMarkup(
    createElement(Fragment, null, renderDiffLineContent(content, undefined, showWhitespace)),
  );
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
