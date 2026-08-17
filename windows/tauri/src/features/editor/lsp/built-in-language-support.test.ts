import { describe, expect, test } from "bun:test";
import {
  isBuiltInLspPath,
  isEditorLspSupported,
  isJavaSourcePath,
  JAVA_LANGUAGE_ID,
  languageIdForEditorFile,
} from "./built-in-language-support";

describe("built-in Java language support", () => {
  test("recognizes Windows and POSIX Java sources", () => {
    expect(isJavaSourcePath("C:\\work\\src\\main\\java\\App.java")).toBe(true);
    expect(isJavaSourcePath("/Users/dev/src/App.java")).toBe(true);
    expect(isJavaSourcePath("C:\\work\\README.md")).toBe(false);
    expect(isJavaSourcePath("remote://host/App.java")).toBe(false);
  });

  test("treats Java as a built-in LSP language without an extension pack", () => {
    expect(isBuiltInLspPath("D:/demo/src/Service.JAVA")).toBe(true);
    expect(isEditorLspSupported("D:/demo/src/Service.java")).toBe(true);
    expect(languageIdForEditorFile("D:/demo/src/Service.java")).toBe(JAVA_LANGUAGE_ID);
  });
});
