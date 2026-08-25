import { describe, expect, test } from "bun:test";
import { documentUsesCrlf, monacoModelMatchesContent, toMonacoModelValue } from "./line-endings";

describe("monaco line endings", () => {
  test("strips CRLF so line text does not keep a trailing carriage return", () => {
    const content = "    private int code;\r\n    private String message;\r\n";

    expect(documentUsesCrlf(content)).toBe(true);
    expect(toMonacoModelValue(content)).toBe("    private int code;\n    private String message;\n");
    expect(toMonacoModelValue(content).split("\n")[0]).toBe("    private int code;");
  });

  test("treats LF and CRLF documents as the same model text", () => {
    const crlf = "class Demo {\r\n}\r\n";
    const lf = "class Demo {\n}\n";

    expect(monacoModelMatchesContent(lf, crlf)).toBe(true);
    expect(monacoModelMatchesContent(crlf, lf)).toBe(true);
  });

  test("leaves LF documents unchanged", () => {
    const content = "private int code;\n";

    expect(documentUsesCrlf(content)).toBe(false);
    expect(toMonacoModelValue(content)).toBe(content);
  });

  test("does not throw when content is missing during editor teardown", () => {
    expect(documentUsesCrlf(undefined as unknown as string)).toBe(false);
    expect(toMonacoModelValue(undefined as unknown as string)).toBe("");
  });
});
