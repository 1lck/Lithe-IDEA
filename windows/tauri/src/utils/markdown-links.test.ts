import { describe, expect, test } from "bun:test";
import { classifyMarkdownLink } from "./markdown-links";

describe("Agent Markdown links", () => {
  test("workspace files keep their line and get a document or code icon", () => {
    expect(classifyMarkdownLink("README.md:12")).toEqual({
      kind: "file",
      path: "README.md",
      line: 12,
      document: true,
    });
    expect(classifyMarkdownLink("src/app.ts#L42")).toEqual({
      kind: "file",
      path: "src/app.ts",
      line: 42,
      document: false,
    });
    expect(classifyMarkdownLink("src/app.ts:42:7")).toMatchObject({
      path: "src/app.ts",
      line: 42,
    });
    expect(classifyMarkdownLink("Makefile:7")).toMatchObject({
      path: "Makefile",
      line: 7,
      document: true,
    });
  });

  test("Windows drive letters are paths, not URL schemes", () => {
    expect(classifyMarkdownLink("C:\\repo\\main.rs:9")).toEqual({
      kind: "file",
      path: "C:\\repo\\main.rs",
      line: 9,
      document: false,
    });
  });

  test("file URLs decode encoded names and keep the anchor line", () => {
    expect(classifyMarkdownLink("file:///C:/work/a%20b.md#L3")).toEqual({
      kind: "file",
      path: "C:/work/a b.md",
      line: 3,
      document: true,
    });
  });

  test("GitHub links get the GitHub icon and other web links stay plain", () => {
    expect(classifyMarkdownLink("https://github.com/1lck/Lithe-IDEA/issues/1207")).toEqual({
      kind: "github",
    });
    expect(classifyMarkdownLink("https://gist.github.com/x")).toEqual({ kind: "github" });
    expect(classifyMarkdownLink("https://example.com/a?b=1")).toEqual({ kind: "web" });
    expect(classifyMarkdownLink("mailto:dev@example.com")).toEqual({ kind: "web" });
    expect(classifyMarkdownLink("#section")).toEqual({ kind: "web" });
  });

  test("telephone links are not mistaken for files", () => {
    expect(classifyMarkdownLink("tel:12345")).toEqual({ kind: "web" });
  });
});
