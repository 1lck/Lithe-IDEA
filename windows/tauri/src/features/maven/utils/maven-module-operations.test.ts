import { describe, expect, test } from "bun:test";
import type { RunConfiguration } from "@/features/run/types/run.types";
import {
  findMavenModuleJavaPath,
  findMavenModuleRunConfiguration,
} from "./maven-module-operations";

function configuration(
  overrides: Partial<RunConfiguration> & Pick<RunConfiguration, "id">,
): RunConfiguration {
  return {
    name: overrides.id,
    provider: "java.main",
    kindTitle: "Java Application",
    execution: "application",
    cwd: "",
    args: [],
    env: {},
    jvmArguments: [],
    programArguments: [],
    profiles: [],
    mavenSkipTests: null,
    javaHomePath: "",
    mavenExecutablePath: "",
    mavenJavaHomePath: "",
    toolchains: { java: "project-jdk" },
    source: "generated",
    disabled: false,
    ...overrides,
  };
}

describe("Maven module operation configuration", () => {
  test("matches a nested reactor module and keeps the configured service", () => {
    const service = configuration({
      id: "spring-boot.maven:backend",
      provider: "spring-boot.maven",
      execution: "service",
      cwd: "projects/demo",
      modulePath: "backend",
      debugAdapter: "jdwp",
      toolchains: { java: "project-jdk", maven: "project-maven" },
    });

    expect(
      findMavenModuleRunConfiguration({
        configurations: [service],
        defaultConfigurationId: null,
        projectRelativePath: "projects/demo",
        moduleRelativePath: "backend",
        mode: "run",
      }),
    ).toBe(service);
  });

  test("uses the project default when a module has several runnable entries", () => {
    const first = configuration({ id: "java-main:First", modulePath: "app" });
    const second = configuration({ id: "java-main:Second", modulePath: "app" });

    expect(
      findMavenModuleRunConfiguration({
        configurations: [first, second],
        defaultConfigurationId: second.id,
        projectRelativePath: ".",
        moduleRelativePath: "app",
        mode: "run",
      }),
    ).toBe(second);
  });

  test("does not guess between ambiguous main classes", () => {
    const first = configuration({ id: "java-main:First", modulePath: "app" });
    const second = configuration({ id: "java-main:Second", modulePath: "app" });

    expect(
      findMavenModuleRunConfiguration({
        configurations: [first, second],
        defaultConfigurationId: null,
        projectRelativePath: ".",
        moduleRelativePath: "app",
        mode: "run",
      }),
    ).toBeNull();
  });

  test("offers Debug only for a JDWP-capable configuration", () => {
    const plain = configuration({ id: "java-main:Plain", modulePath: "app" });
    const debug = configuration({
      id: "spring-boot.maven:app",
      provider: "spring-boot.maven",
      execution: "service",
      modulePath: "app",
      debugAdapter: "jdwp",
    });

    expect(
      findMavenModuleRunConfiguration({
        configurations: [plain],
        defaultConfigurationId: null,
        projectRelativePath: ".",
        moduleRelativePath: "app",
        mode: "debug",
      }),
    ).toBeNull();
    expect(
      findMavenModuleRunConfiguration({
        configurations: [plain, debug],
        defaultConfigurationId: null,
        projectRelativePath: ".",
        moduleRelativePath: "app",
        mode: "debug",
      }),
    ).toBe(debug);
  });

  test("accepts an overridden working directory when the module match is unique", () => {
    const service = configuration({
      id: "quarkus.maven:api",
      provider: "quarkus.maven",
      execution: "service",
      cwd: "D:/custom-working-directory",
      modulePath: "api",
    });

    expect(
      findMavenModuleRunConfiguration({
        configurations: [service],
        defaultConfigurationId: null,
        projectRelativePath: "reactor",
        moduleRelativePath: "api",
        mode: "run",
      }),
    ).toBe(service);
  });

  test("chooses a deterministic Java source inside the selected module", () => {
    expect(
      findMavenModuleJavaPath(
        [
          "reactor/web/src/main/java/Web.java",
          "reactor/backend/src/test/java/AppTest.java",
          "reactor/backend/src/main/java/App.java",
        ],
        "reactor",
        "backend",
      ),
    ).toBe("reactor/backend/src/main/java/App.java");
    expect(findMavenModuleJavaPath(["other/App.java"], "reactor", "backend")).toBeNull();
  });
});
