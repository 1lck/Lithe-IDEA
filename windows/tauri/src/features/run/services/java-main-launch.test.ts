import { describe, expect, mock, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { editJavaMainConfiguration, javaMainConfiguration } from "./java-main-launch";

function configuration(overrides: Partial<RunConfiguration>): RunConfiguration {
  return {
    id: "generated-app",
    name: "App",
    provider: "java.main",
    kindTitle: "Application",
    execution: "application",
    category: "project",
    mainClass: "demo.App",
    sourcePath: "src/main/java/demo/App.java",
    cwd: ".",
    args: [],
    env: {},
    jvmArguments: [],
    programArguments: [],
    profiles: [],
    mavenSkipTests: null,
    javaHomePath: "",
    mavenExecutablePath: "",
    mavenJavaHomePath: "",
    toolchains: {},
    source: "generated",
    disabled: false,
    ...overrides,
  };
}

describe("configuration for a main marker", () => {
  test("editing a main marker selects its settings form before opening Settings", async () => {
    const calls: string[] = [];
    const resolve = mock(async () => configuration({ id: "service-a" }));
    await editJavaMainConfiguration("workspace-a", "src/App.java", "demo.App", {
      resolve,
      edit: (workspace, id) => {
        calls.push(`${workspace}:${id}`);
      },
      openSettings: () => {
        calls.push("settings");
      },
    });
    expect(resolve).toHaveBeenCalledWith("workspace-a", "src/App.java", "demo.App");
    expect(calls).toEqual(["workspace-a:service-a", "settings"]);
  });

  test("failed main resolution does not open an unrelated settings form", async () => {
    const edit = mock(() => {});
    const openSettings = mock(() => {});
    await expect(
      editJavaMainConfiguration("workspace-a", "src/App.java", "demo.App", {
        resolve: async () => {
          throw new Error("No configuration");
        },
        edit,
        openSettings,
      }),
    ).rejects.toThrow("No configuration");
    expect(edit).not.toHaveBeenCalled();
    expect(openSettings).not.toHaveBeenCalled();
  });

  const sourcePath = "src/main/java/demo/App.java";

  test("matches both the class and the source file", () => {
    const configurations = [
      configuration({ id: "other-module", sourcePath: "other/src/main/java/demo/App.java" }),
      configuration({ id: "generated-app" }),
    ];
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.App")?.id).toBe(
      "generated-app",
    );
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.Other")).toBeNull();
  });

  test("reuses an edited copy over the generated entry, and the selection over both", () => {
    const configurations = [
      configuration({ id: "generated-app" }),
      configuration({ id: "local-app", source: "local" }),
      configuration({ id: "project-app", source: "project" }),
    ];
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.App")?.id).toBe(
      "local-app",
    );
    expect(javaMainConfiguration(configurations, "generated-app", sourcePath, "demo.App")?.id).toBe(
      "generated-app",
    );
  });

  test("never picks a disabled configuration", () => {
    expect(
      javaMainConfiguration(
        [configuration({ id: "disabled", disabled: true })],
        "disabled",
        sourcePath,
        "demo.App",
      ),
    ).toBeNull();
  });
});
