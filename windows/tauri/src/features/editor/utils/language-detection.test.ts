import { describe, expect, test } from "bun:test";
import { detectLanguageFromFileName, detectLanguageFromPath } from "./language-detection";

describe("editor language detection fallbacks", () => {
  test("properties use the bundled INI tokenizer before plugins initialize", () => {
    expect(detectLanguageFromPath("C:\\work\\messages_ZH.PROPERTIES")).toBe("ini");
    expect(detectLanguageFromFileName("application.properties")).toBe("ini");
  });
  test("recognizes Java sources even before extension contributions initialize", () => {
    expect(detectLanguageFromPath("C:\\work\\src\\DirectUploadService.JAVA")).toBe("java");
    expect(detectLanguageFromFileName("DirectUploadService.java")).toBe("java");
  });
});
