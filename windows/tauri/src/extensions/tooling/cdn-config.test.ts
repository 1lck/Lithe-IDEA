import { describe, expect, test } from "bun:test";
import { resolveExtensionsCdnBaseUrl } from "./cdn-config";

describe("extension CDN tooling configuration", () => {
  test("requires an explicitly configured CDN URL", () => {
    expect(() => resolveExtensionsCdnBaseUrl(undefined)).toThrow("EXTENSIONS_CDN_BASE_URL");
    expect(() => resolveExtensionsCdnBaseUrl("   ")).toThrow("EXTENSIONS_CDN_BASE_URL");
  });

  test("rejects relative and non-HTTP URLs", () => {
    expect(() => resolveExtensionsCdnBaseUrl("/extensions")).toThrow("absolute HTTP(S) URL");
    expect(() => resolveExtensionsCdnBaseUrl("file:///tmp/extensions")).toThrow(
      "absolute HTTP(S) URL",
    );
  });

  test("rejects query parameters", () => {
    expect(() =>
      resolveExtensionsCdnBaseUrl("https://cdn.example.test/extensions?token=abc"),
    ).toThrow("must not contain a query or fragment");
  });

  test("rejects fragments", () => {
    expect(() =>
      resolveExtensionsCdnBaseUrl("https://cdn.example.test/extensions#packages"),
    ).toThrow("must not contain a query or fragment");
  });

  test("rejects empty query and fragment delimiters", () => {
    for (const suffix of ["?", "#", "?#"]) {
      expect(() =>
        resolveExtensionsCdnBaseUrl(`https://cdn.example.test/extensions${suffix}`),
      ).toThrow("must not contain a query or fragment");
    }
  });

  test("normalizes a valid explicit CDN URL", () => {
    expect(resolveExtensionsCdnBaseUrl(" https://cdn.example.test/extensions/// ")).toBe(
      "https://cdn.example.test/extensions",
    );
  });
});
