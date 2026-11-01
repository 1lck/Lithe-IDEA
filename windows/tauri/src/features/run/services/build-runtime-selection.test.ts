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
