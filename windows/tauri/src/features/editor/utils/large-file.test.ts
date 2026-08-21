import { describe, expect, test } from "bun:test";
import {
  applyEditorTextChangeToLargeEditorModeInfo,
  applyIncrementalLargeEditorModeInfo,
  getLargeEditorModeInfo,
  isTooLargeForEditorServices,
} from "./large-file";

describe("large editor service gating", () => {
  test("treats 2 MiB files as too large for expensive editor services", () => {
    expect(
      isTooLargeForEditorServices({
        contentLength: 2 * 1024 * 1024,
        lineCount: 10,
      }),
    ).toBe(true);
  });

  test("treats 50,000-line files as too large for expensive editor services", () => {
    expect(
      isTooLargeForEditorServices({
        contentLength: 100,
        lineCount: 50_000,
      }),
    ).toBe(true);
  });

  test("does not build unused line offsets on the typing path", () => {
    const info = getLargeEditorModeInfo("one\ntwo\nthree");
    expect(info.lineCount).toBe(3);
    expect(info.lineOffsets).toBeUndefined();
  });

  test("updates line count from a range change without scanning the document", () => {
    const previous = getLargeEditorModeInfo("one\ntwo");
    const next = applyEditorTextChangeToLargeEditorModeInfo(
      previous,
      { text: "\nthree", startLine: 1, endLine: 1 },
      "one\ntwo\nthree".length,
    );
    expect(next?.lineCount).toBe(3);
    expect(next?.lineOffsets).toBeUndefined();
  });

  test("falls back to a prefix/suffix incremental update", () => {
    const previous = getLargeEditorModeInfo("one\ntwo");
    const next = applyIncrementalLargeEditorModeInfo("one\ntwo", "one\ntwo\nthree", previous);
    expect(next?.lineCount).toBe(3);
  });
});
