import { describe, expect, spyOn, test } from "bun:test";
import * as core from "@/features/run/api/run-core-api";
import * as host from "@/platform/tauri-core";
import { resolveJavaLspLaunch } from "./java-lsp-host-api";

describe("project JDK passed to the Java language service", () => {
  for (const homePath of ["D:/tools/custom-jdk-25", undefined]) {
    test(`reads authoritative project configuration (${homePath ?? "automatic"})`, async () => {
      const inspect = spyOn(core, "inspectRunConfiguration").mockResolvedValue({
        status: "ready", toolchain: { java: { homePath } },
      });
      const launch = { providerId: "java", languageId: "java", executablePath: "jdtls", arguments: [], cacheDirectory: "D:/cache", environment: {}, javaRuntimes: [{ homePath: "D:/jdk-25", version: "25", isDefault: true }] };
      const invoke = spyOn(host, "invoke").mockResolvedValue(launch);
      try {
        expect(await resolveJavaLspLaunch("D:/workspace")).toBe(launch);
        expect(inspect).toHaveBeenCalledWith("D:/workspace", false);
        expect(invoke).toHaveBeenCalledWith("lsp_resolve_java_launch", {
          workspacePath: "D:/workspace", projectJavaHome: homePath ?? "",
        });
      } finally { inspect.mockRestore(); invoke.mockRestore(); }
    });
  }

  test("a configuration read failure does not silently launch with another JDK", async () => {
    const inspect = spyOn(core, "inspectRunConfiguration").mockRejectedValue(new Error("read failed"));
    const invoke = spyOn(host, "invoke").mockResolvedValue({});
    try {
      await expect(resolveJavaLspLaunch("D:/workspace")).rejects.toThrow("read failed");
      expect(invoke).not.toHaveBeenCalled();
    } finally { inspect.mockRestore(); invoke.mockRestore(); }
  });
});
