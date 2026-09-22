import { describe, expect, test } from "bun:test";
import { parseRawDiffContent } from "./git-diff-parser";

describe("git diff parser line endings", () => {
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
