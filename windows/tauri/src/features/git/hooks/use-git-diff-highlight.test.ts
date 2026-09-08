import { describe, expect, test } from "bun:test";
import { createLineBasedDiffTokenMap } from "./use-git-diff-highlight";
import type { GitDiffLine } from "../types/git.types";

function makeLine(
  content: string,
  lineType: GitDiffLine["line_type"],
  lineNumber: number,
): GitDiffLine {
  return {
    content,
    line_type: lineType,
    old_line_number: lineType === "added" ? undefined : lineNumber,
    new_line_number: lineType === "removed" ? undefined : lineNumber,
  };
}

describe("createLineBasedDiffTokenMap", () => {
  test("returns no tokens for xml because line-based fallback is unavailable", () => {
    const lines = [
      makeLine("<project>", "context", 1),
      makeLine("  <dependency>", "added", 2),
      makeLine("  </dependency>", "added", 3),
      makeLine("</project>", "context", 4),
    ];

    expect(createLineBasedDiffTokenMap(lines, "stat-agg/pom.xml").size).toBe(0);
  });
});

describe("xml highlight query contract", () => {
  test("does not capture nested content nodes that span child elements", async () => {
    const query = await Bun.file(
      new URL("../../../../public/tree-sitter/parsers/xml/highlights.scm", import.meta.url),
    ).text();

    expect(query).not.toMatch(/\(content\)\s+@string/);
    expect(query).toContain("(tag_name) @tag");
    expect(query).toContain("(attribute_value) @string");
  });
});
