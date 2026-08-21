import { createElement, Fragment } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "bun:test";
import { renderDiffLineContent } from "./git-diff-line";

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
