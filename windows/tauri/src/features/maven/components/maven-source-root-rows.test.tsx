import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MavenSourceRootRows } from "./maven-source-root-rows";

describe("Maven source-root rows", () => {
  test("renders each root path with its source-set category", () => {
    const markup = renderToStaticMarkup(
      createElement(MavenSourceRootRows, {
        sourceRoots: [
          { path: "src/main/java", kind: "mainJava" },
          { path: "src/test/java", kind: "testJava" },
          { path: "target/generated-sources", kind: "generatedMain" },
        ],
      }),
    );

    expect(markup).toContain("src/main/java");
    expect(markup).toContain("main Java");
    expect(markup).toContain("src/test/java");
    expect(markup).toContain("test Java");
    expect(markup).toContain("target/generated-sources");
    expect(markup).toContain("generated main");
  });
});
