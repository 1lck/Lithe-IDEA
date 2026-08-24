import { describe, expect, test } from "bun:test";
import { detectLanguageFromFileName, detectLanguageFromPath } from "./language-detection";

describe("editor language detection fallbacks", () => {
  test("recognizes Java sources even before extension contributions initialize", () => {
    expect(detectLanguageFromPath("C:\\work\\src\\DirectUploadService.JAVA")).toBe("java");
    expect(detectLanguageFromFileName("DirectUploadService.java")).toBe("java");
  });
});
