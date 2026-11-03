import { describe, expect, test } from "bun:test";
import { detectLanguageFromFileName, detectLanguageFromPath } from "./language-detection";
import { getLanguageIdFromPath } from "./language-id";
import fixture from "../../../../../../shared/fixtures/editor/basic-file-highlighting-v1.json";

describe("editor language detection fallbacks", () => {
  test("basic syntax associations reach every Windows language selection entry", () => {
    for (const { filename, language } of fixture.associations) {
      expect(detectLanguageFromFileName(filename)).toBe(language);
      expect(detectLanguageFromPath(`C:\\workspace\\${filename}`)).toBe(language);
      expect(getLanguageIdFromPath(`C:\\workspace\\${filename}`)).toBe(language);
    }
  });
  test("properties use the bundled INI tokenizer before plugins initialize", () => {
    expect(detectLanguageFromPath("C:\\work\\messages_ZH.PROPERTIES")).toBe("ini");
    expect(detectLanguageFromFileName("application.properties")).toBe("ini");
  });
  test("recognizes Java sources even before extension contributions initialize", () => {
    expect(detectLanguageFromPath("C:\\work\\src\\DirectUploadService.JAVA")).toBe("java");
    expect(detectLanguageFromFileName("DirectUploadService.java")).toBe("java");
  });
});
