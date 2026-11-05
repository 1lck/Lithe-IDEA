import { describe, expect, test } from "bun:test";
import { encodeMonacoSemanticTokens } from "./semantic-tokens";
import {
  foldingSpans, hoverSections, lensItems, linkItems, linkUrl, mergeSemanticResponses, parseLinkUrl, toSpan,
} from "./plugin-editor-provider-rules";

const span = (line: number, from: number, to: number) =>
  ({ start: { line, character: from }, end: { line, character: to } });

describe("plugin editor provider rules", () => {
  test("convert zero-based LSP ranges to one-based spans and refuse foreign ones", () => {
    expect(toSpan(span(0, 2, 8), 3)).toEqual({ startLineNumber: 1, startColumn: 3, endLineNumber: 1, endColumn: 9 });
    expect(toSpan(span(3, 0, 1), 3)).toBeUndefined();
    expect(toSpan(span(1, 5, 2), 3)).toBeUndefined();
    expect(toSpan({ start: { line: -1, character: 0 }, end: { line: 0, character: 0 } }, 3)).toBeUndefined();
    expect(toSpan(undefined, 3)).toBeUndefined();
  });

  test("hover keeps markdown and escapes plain text; a missing list is empty", () => {
    const sections = hoverSections({ contents: [
      { kind: "markdown", value: "**bold** `code`" },
      { kind: "plaintext", value: "a*b_c" },
      { kind: "markdown", value: "" },
      "not an object",
    ] });

    expect(sections.map(item => item.value)).toEqual(["**bold** `code`", "a\\*b\\_c"]);
    expect(sections.every(item => item.isTrusted === false && item.supportHtml === false)).toBe(true);
    expect(hoverSections({})).toEqual([]);
    expect(hoverSections(undefined)).toEqual([]);
  });

  test("folding ranges are one-based, multi-line and inside the document", () => {
    expect(foldingSpans({ ranges: [
      { startLine: 0, endLine: 3, kind: "imports" },
      { startLine: 2, endLine: 2 },
      { startLine: 1, endLine: 9 },
      { startLine: 4, endLine: 5, kind: "bogus" },
      { startLine: 6, endLine: 10 },
    ] }, 10)).toEqual([
      { start: 1, end: 4, kind: "imports" },
      { start: 2, end: 10, kind: undefined },
      { start: 5, end: 6, kind: undefined },
    ]);
    expect(foldingSpans(undefined, 10)).toEqual([]);
  });

  test("lenses and links need a batch and a span inside the document", () => {
    const lenses = lensItems({ batch: "b1", lenses: [
      { id: "l1", range: span(1, 0, 3), title: "3 usages" },
      { id: "l2", range: span(9, 0, 3), title: "outside" },
      { id: 4, range: span(0, 0, 1), title: "bad id" },
    ] }, 4);
    expect(lenses.batch).toBe("b1");
    expect(lenses.lenses.map(item => item.id)).toEqual(["l1"]);
    expect(lenses.lenses[0].range.startLineNumber).toBe(2);
    expect(lensItems({ batch: "", lenses: [{ id: "l", range: span(0, 0, 1), title: "t" }] }, 4).lenses).toEqual([]);

    const links = linkItems({ batch: "b2", links: [
      { id: "k1", range: span(0, 1, 5), tooltip: "Open" },
      { id: "k2", range: span(0, 1, 5) },
      { range: span(0, 1, 5) },
    ] }, 4);
    expect(links.links.map(item => [item.id, item.tooltip])).toEqual([["k1", "Open"], ["k2", undefined]]);
    expect(linkItems({}, 4)).toEqual({ batch: "", links: [] });
  });

  test("link URLs carry only the host's opaque batch and key", () => {
    const url = linkUrl("b-1", "k 1");
    expect(url).toBe("lithe-plugin-link:/b-1/k%201");
    expect(parseLinkUrl(url)).toEqual({ batch: "b-1", id: "k 1" });
    expect(parseLinkUrl("https://example.com/a")).toBeUndefined();
    expect(parseLinkUrl("command:editor.action.selectAll")).toBeUndefined();
  });

  test("merge semantic answers with different legends into one token list", () => {
    const merged = mergeSemanticResponses([
      { legend: { tokenTypes: ["property"], tokenModifiers: ["readonly"] }, data: [0, 0, 3, 0, 1] },
      { legend: { tokenTypes: ["keyword", "property"], tokenModifiers: ["static"] }, data: [1, 2, 4, 1, 1, 0, 6, 2, 0, 0] },
    ]);

    expect(merged.tokenTypes).toEqual(["property", "keyword"]);
    expect(merged.tokenModifiers).toEqual(["readonly", "static"]);
    expect(merged.tokens).toEqual([
      { line: 0, startChar: 0, length: 3, tokenType: 0, tokenModifiers: 1 },
      { line: 1, startChar: 2, length: 4, tokenType: 0, tokenModifiers: 2 },
      { line: 1, startChar: 8, length: 2, tokenType: 1, tokenModifiers: 0 },
    ]);

    const model = { getLineCount: () => 3, getLineMaxColumn: () => 40 };
    expect(Array.from(encodeMonacoSemanticTokens(merged, model)).length).toBe(15);
    expect(mergeSemanticResponses("nope").tokens).toEqual([]);
    expect(mergeSemanticResponses([{ legend: { tokenTypes: [], tokenModifiers: [] }, data: [0, 0, 1] }]).tokens).toEqual([]);
  });
});
