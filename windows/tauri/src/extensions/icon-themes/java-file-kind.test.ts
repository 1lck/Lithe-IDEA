import { describe, expect, test } from "bun:test";
import { detectJavaFileIconSemanticKind, type JavaFileIconSemanticKind } from "./java-file-kind";

describe("Java file icon semantics", () => {
  const cases: Array<{
    fileName: string;
    source: string;
    expected: JavaFileIconSemanticKind;
  }> = [
    { fileName: "Example.java", source: "public class Example {}", expected: "java.class" },
    {
      fileName: "Example.java",
      source: "public interface Example {}",
      expected: "java.interface",
    },
    {
      fileName: "Example.java",
      source: "public enum Example { VALUE }",
      expected: "java.enum",
    },
    {
      fileName: "Example.java",
      source: "public @interface Example {}",
      expected: "java.annotation",
    },
    {
      fileName: "Example.java",
      source: "public record Example(String value) {}",
      expected: "java.record",
    },
    {
      fileName: "Example.java",
      source: "public class Example extends java.lang.RuntimeException {}",
      expected: "java.exception",
    },
  ];

  test.each(cases)("detects $fileName as $expected", ({ fileName, source, expected }) => {
    expect(detectJavaFileIconSemanticKind(fileName, source)).toBe(expected);
  });

  test("ignores declarations inside comments, strings, text blocks, and nested types", () => {
    const source = `
      // class Example {}
      class Container {
        String text = "interface Example {}";
        String block = """enum Example { VALUE }""";
        class Example {}
      }
    `;

    expect(detectJavaFileIconSemanticKind("Example.java", source)).toBeNull();
  });

  test("uses the matching top-level declaration instead of the first declaration", () => {
    const source = "class Helper {}\npublic interface Example {}";
    expect(detectJavaFileIconSemanticKind("Example.java", source)).toBe("java.interface");
  });

  test("does not infer exception semantics from a filename or custom base class", () => {
    expect(
      detectJavaFileIconSemanticKind(
        "ExampleException.java",
        "class ExampleException extends DomainFailure {}",
      ),
    ).toBe("java.class");
    expect(detectJavaFileIconSemanticKind("Other.java", "class Example {}")).toBeNull();
  });

  test("does not confuse a generic bound with the direct superclass", () => {
    expect(
      detectJavaFileIconSemanticKind("Example.java", "class Example<T extends Exception> {}"),
    ).toBe("java.class");
    expect(
      detectJavaFileIconSemanticKind(
        "Example.java",
        "class Example<T extends Comparable<T>> extends RuntimeException {}",
      ),
    ).toBe("java.exception");
  });
});
