import { describe, expect, test } from "bun:test";
import {
  JavaClipboardPasteError,
  assertLocalJavaPasteDirectory,
  requireCreatedFilePath,
} from "./paste-java-class-from-clipboard";

describe("assertLocalJavaPasteDirectory", () => {
  test("rejects remote targets before any file is created", () => {
    expect(() => assertLocalJavaPasteDirectory("remote://conn/src/main/java")).toThrow(
      JavaClipboardPasteError,
    );
    try {
      assertLocalJavaPasteDirectory("remote://conn/src/main/java");
    } catch (error) {
      expect(error).toBeInstanceOf(JavaClipboardPasteError);
      expect((error as JavaClipboardPasteError).code).toBe("remote");
    }
  });

  test("allows local directories", () => {
    expect(() => assertLocalJavaPasteDirectory("D:\\project\\src\\main\\java")).not.toThrow();
  });
});

describe("requireCreatedFilePath", () => {
  test("fails when createFileInDirectory does not return a path", () => {
    expect(() => requireCreatedFilePath(undefined, "Demo.java")).toThrow(JavaClipboardPasteError);
    try {
      requireCreatedFilePath(undefined, "Demo.java");
    } catch (error) {
      expect(error).toBeInstanceOf(JavaClipboardPasteError);
      expect((error as JavaClipboardPasteError).code).toBe("create-failed");
      expect((error as JavaClipboardPasteError).fileName).toBe("Demo.java");
    }
  });

  test("returns the created path", () => {
    expect(requireCreatedFilePath("D:\\project\\Demo.java", "Demo.java")).toBe(
      "D:\\project\\Demo.java",
    );
  });
});
