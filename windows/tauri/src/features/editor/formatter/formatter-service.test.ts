import { describe, expect, test } from "bun:test";
import { isFormattingAvailable } from "./formatter-service";

describe("formatting availability", () => {
  // Regression for #832: Java uses the bundled JDT LS rather than an extension
  // LSP, so the format command must not reject it before asking the server.
  test("offers formatting for Java sources served by the built-in language server", () => {
    expect(isFormattingAvailable("C:\\work\\src\\main\\java\\Main.java", "java")).toBe(true);
    expect(isFormattingAvailable("D:/demo/src/Service.JAVA")).toBe(true);
  });

  test("does not offer formatting for files without a formatter or language server", () => {
    expect(isFormattingAvailable("C:\\work\\notes.unknown-format")).toBe(false);
    expect(isFormattingAvailable("wsl://Ubuntu/home/dev/Main.java", "java")).toBe(false);
  });
});
