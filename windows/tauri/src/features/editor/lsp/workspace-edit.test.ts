import { describe, expect, test } from "bun:test";
import { filePathFromUri } from "./workspace-edit";

describe("LSP file URI paths", () => {
  test("removes the URI slash before a Windows drive", () => {
    expect(filePathFromUri("file:///C:/work/src/Main.java")).toBe("C:/work/src/Main.java");
  });

  test("preserves UNC hosts", () => {
    expect(filePathFromUri("file://server/share/src/Main.java")).toBe(
      "//server/share/src/Main.java",
    );
  });

  test("keeps POSIX absolute paths absolute", () => {
    expect(filePathFromUri("file:///Users/dev/src/Main.java")).toBe("/Users/dev/src/Main.java");
  });

  test("decodes escaped path segments", () => {
    expect(filePathFromUri("file:///C:/work/My%20Project/Main.java")).toBe(
      "C:/work/My Project/Main.java",
    );
  });

  test("keeps malformed escape sequences readable", () => {
    expect(filePathFromUri("file:///C:/work/%invalid/Main.java")).toBe(
      "C:/work/%invalid/Main.java",
    );
  });
});
