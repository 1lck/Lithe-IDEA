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

  // Without workspace roots the resolver still only accepts known documents,
  // which keeps every caller that has not opted into workspace diagnostics on
  // its previous behavior.
  test("keeps POSIX paths case-sensitive and rejects closed documents", () => {
    expect(
      resolvePublishedDiagnosticsFilePath("/workspace/Main.java", ["/workspace/main.java"], []),
    ).toBeNull();
    expect(resolvePublishedDiagnosticsFilePath("C:/work/Main.java", [], [])).toBeNull();
  });
});

describe("workspace-scoped published diagnostics", () => {
  const workspaceRoot = "C:\\Work\\RuoYi-Vue-Plus";

  test("keeps diagnostics for an unopened file inside a workspace root", () => {
    // Reproduces the RuoYi-Vue-Plus launch failure: the build gate reports
    // compilation errors in a module the user never opened, so those markers
    // must survive to be actionable.
    expect(
      resolvePublishedDiagnosticsFilePath(
        "C:/Work/RuoYi-Vue-Plus/ruoyi-workflow/src/main/java/org/dromara/Flow.java",
        [],
        [],
        [workspaceRoot],
      ),
    ).toBe("C:/Work/RuoYi-Vue-Plus/ruoyi-workflow/src/main/java/org/dromara/Flow.java");
  });

  test("prefers the concrete buffer path over the published spelling", () => {
    const bufferPath = "C:\\Work\\RuoYi-Vue-Plus\\ruoyi-admin\\Main.java";

    expect(
      resolvePublishedDiagnosticsFilePath(
        "c:/work/ruoyi-vue-plus/ruoyi-admin/main.java",
        [bufferPath],
        [],
        [workspaceRoot],
      ),
    ).toBe(bufferPath);
  });

  test("drops diagnostics for files outside every workspace root", () => {
    // JDK sources, dependency jars, and decompiled class files land here.
    expect(
      resolvePublishedDiagnosticsFilePath(
        "C:/Users/dev/.m2/repository/org/example/Example.java",
        [],
        [],
        [workspaceRoot],
      ),
    ).toBeNull();
  });

  test("does not treat a sibling directory sharing a name prefix as contained", () => {
    expect(
      resolvePublishedDiagnosticsFilePath(
        "C:/Work/RuoYi-Vue-Plus-backup/Main.java",
        [],
        [],
        [workspaceRoot],
      ),
    ).toBeNull();
  });

  test("normalizes separators so the store uses one spelling per file", () => {
    expect(
      resolvePublishedDiagnosticsFilePath(
        "C:\\Work\\RuoYi-Vue-Plus\\ruoyi-system\\Svc.java",
        [],
        [],
        [workspaceRoot],
      ),
    ).toBe("C:/Work/RuoYi-Vue-Plus/ruoyi-system/Svc.java");
  });

  test("keeps POSIX workspace containment case-sensitive", () => {
    expect(
      resolvePublishedDiagnosticsFilePath("/workspace/src/Main.java", [], [], ["/workspace"]),
    ).toBe("/workspace/src/Main.java");
    expect(
      resolvePublishedDiagnosticsFilePath("/Workspace/src/Main.java", [], [], ["/workspace"]),
    ).toBeNull();
  });
});
