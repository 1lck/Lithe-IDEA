import { describe, expect, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { javaMainConfiguration } from "./java-main-launch";

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
    expect(
      javaMainConfiguration(configurations, "generated-app", sourcePath, "demo.App")?.id,
    ).toBe("generated-app");
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
