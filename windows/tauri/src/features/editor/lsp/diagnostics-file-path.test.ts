import { describe, expect, test } from "bun:test";
import { resolvePublishedDiagnosticsFilePath } from "./diagnostics-file-path";

describe("published diagnostics file paths", () => {
  test("returns the concrete Windows buffer path across separator and case differences", () => {
    const bufferPath = "C:\\Work\\src\\Main.java";

    expect(
      resolvePublishedDiagnosticsFilePath(
        "c:/work/src/main.java",
        [bufferPath],
        ["c:/work/src/main.java"],
      ),
    ).toBe(bufferPath);
  });

  test("uses a tracked document path when the source buffer is not mounted", () => {
    const trackedPath = "C:\\work\\src\\Main.java";

    expect(resolvePublishedDiagnosticsFilePath("C:/work/src/Main.java", [], [trackedPath])).toBe(
      trackedPath,
    );
  });

  test("compares UNC paths case-insensitively", () => {
    const bufferPath = "\\\\SERVER\\Share\\Main.java";

    expect(resolvePublishedDiagnosticsFilePath("//server/share/main.java", [bufferPath], [])).toBe(
      bufferPath,
    );
  });

  test("keeps POSIX paths case-sensitive and rejects closed documents", () => {
    expect(
      resolvePublishedDiagnosticsFilePath("/workspace/Main.java", ["/workspace/main.java"], []),
    ).toBeNull();
    expect(resolvePublishedDiagnosticsFilePath("C:/work/Main.java", [], [])).toBeNull();
  });
});
