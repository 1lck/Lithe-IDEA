import { describe, expect, test } from "bun:test";
import { parseRawDiffContent } from "./git-diff-parser";

describe("git diff parser line endings", () => {
  test.each(["\n", "\r\n"])("keeps multi-file paths and line numbers with %j separators", (separator) => {
    const diff = parseRawDiffContent([
      "diff --git a/old.ts b/new.ts",
      "similarity index 100%",
      "rename from old.ts",
      "rename to new.ts",
      "diff --git a/added.ts b/added.ts",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/added.ts",
      "@@ -0,0 +1,2 @@",
      "+first\rmiddle",
      "+",
      "",
    ].join(separator), "changes.patch");
    expect("files" in diff).toBe(true);
    if (!("files" in diff)) throw new Error("Expected a multi-file diff");
    expect(diff.fileKeys).toEqual(["new.ts", "added.ts"]);
    expect(diff.files[0]).toMatchObject({ old_path: "old.ts", new_path: "new.ts", is_renamed: true });
    expect(diff.files[1].is_new).toBe(true);
    expect(diff.files[1].lines.slice(1)).toEqual([
      { line_type: "added", content: "first\rmiddle", old_line_number: undefined, new_line_number: 1 },
      { line_type: "added", content: "", old_line_number: undefined, new_line_number: 2 },
    ]);
    expect(diff.totalAdditions).toBe(2);
    expect(diff.totalDeletions).toBe(0);
  });

  test("normalizes Windows CRLF output before exposing diff lines", () => {
    const diff = parseRawDiffContent(
      [
        "diff --git a/src/example.ts b/src/example.ts",
        "index 1234567..7654321 100644",
        "--- a/src/example.ts",
        "+++ b/src/example.ts",
        "@@ -1,1 +1,1 @@",
        "-before",
        "+after",
      ].join("\r\n"),
      "src/example.ts",
    );

    expect("files" in diff).toBe(false);
    if ("files" in diff) return;

    expect(diff.file_path).toBe("src/example.ts");
    expect(diff.old_path).toBe("src/example.ts");
    expect(diff.new_path).toBe("src/example.ts");
    expect(diff.lines.map((line) => line.content)).toEqual([
      "@@ -1,1 +1,1 @@",
      "before",
      "after",
    ]);
    expect(diff.lines.every((line) => !line.content.includes("\r"))).toBe(true);
  });
});
