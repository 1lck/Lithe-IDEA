import { expect, test } from "bun:test";
import { selectedBuildRuntimeExecutables } from "./build-runtime-selection";

test("build uses Core's existing local JDK selection and opaque runtime IDs without probing", async () => {
  const reads: unknown[] = [];
  const result = await selectedBuildRuntimeExecutables("C:/fixture", async (...args) => {
    reads.push(args);
    return { status: "ready", toolchain: { java: { homePath: "C:/selected-jdk" } },
      localToolchains: { version: 1, toolchains: { "opaque-runtime": { executable: "C:/runtime/tool.exe" } } } };
  });
  expect(reads).toEqual([["C:/fixture", false]]);
  expect(result).toEqual({ java: "C:/selected-jdk/bin/java.exe", "opaque-runtime": "C:/runtime/tool.exe" });
});

test("explicit runtime selection wins over the legacy Java-home adapter", async () => {
  const result = await selectedBuildRuntimeExecutables("C:/fixture", async () => ({ status: "ready",
    toolchain: { java: { homePath: "C:/legacy-jdk" } },
    localToolchains: { version: 1, toolchains: { java: { executable: "C:/explicit-jdk/bin/java.exe" } } },
  }));
  expect(result.java).toBe("C:/explicit-jdk/bin/java.exe");
});

test("missing preferences remain automatic and read failures never fall back to another JDK", async () => {
  expect(await selectedBuildRuntimeExecutables("C:/fixture", async () => ({ status: "ready" }))).toEqual({});
  const failure = new Error("read refused");
  await expect(selectedBuildRuntimeExecutables("C:/fixture", async () => { throw failure; })).rejects.toBe(failure);
});

test("project-scoped runtime paths use the same workspace root as Run and JDT", async () => {
  const result = await selectedBuildRuntimeExecutables("C:/workspace with spaces", async () => ({
    status: "ready", toolchain: { java: { homePath: ".lithe/toolchains/jdk" } },
    localToolchains: { version: 1, toolchains: {
      "opaque-runtime": { executable: "tools/runtime.exe" },
    } },
  }));
  expect(result).toEqual({
    java: "C:/workspace with spaces/.lithe/toolchains/jdk/bin/java.exe",
    "opaque-runtime": "C:/workspace with spaces/tools/runtime.exe",
  });
});

test("absolute UNC selections and malformed drive-relative selections retain native validation", async () => {
  const result = await selectedBuildRuntimeExecutables("C:/workspace", async () => ({
    status: "ready", localToolchains: { version: 1, toolchains: {
      java: { executable: "\\\\server\\share\\jdk\\bin\\java.exe" },
      "opaque-runtime": { executable: "D:unavailable.exe" },
    } },
  }));
  expect(result).toEqual({ java: "//server/share/jdk/bin/java.exe", "opaque-runtime": "D:unavailable.exe" });
});
