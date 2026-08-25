import { describe, expect, test } from "bun:test";
import { isUtf8WithinByteLimit } from "./utf8-byte-limit";

describe("isUtf8WithinByteLimit", () => {
  test("measures ASCII source by UTF-8 bytes", () => {
    expect(isUtf8WithinByteLimit("class", 5)).toBe(true);
    expect(isUtf8WithinByteLimit("class", 4)).toBe(false);
  });

  test("counts multibyte characters and surrogate pairs by encoded size", () => {
    expect(isUtf8WithinByteLimit("é中😀", 9)).toBe(true);
    expect(isUtf8WithinByteLimit("é中😀", 8)).toBe(false);
  });

  test("matches TextEncoder replacement semantics for unpaired surrogates", () => {
    expect(isUtf8WithinByteLimit("\ud800", 3)).toBe(true);
    expect(isUtf8WithinByteLimit("\ud800", 2)).toBe(false);
  });
});
