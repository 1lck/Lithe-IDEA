import { describe, expect, test } from "bun:test";
import type { RunConfiguration } from "@/features/run/types/run.types";
import { mapCoreConfiguration } from "@/features/run/utils/run-configuration";
import ownershipFixture from "../../../../../../shared/fixtures/run-configuration/maven-module-ownership.json";
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
    mavenReactorPath: ".",
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
  // Rust runs this fixture through generate/resolve; these are the verified menu-facing fields.
  const resolved = ownershipFixture.expected.configurations.map(mapCoreConfiguration);

  test("limits a global default to the selected reactor even when both modules are root", () => {
    const selected = findMavenModuleRunConfiguration({
      configurations: resolved,
      defaultConfigurationId: "java-main:example.Beta",
      projectRelativePath: "services/alpha",
      moduleRelativePath: ".",
      mode: "run",
    });
    expect(selected?.id).toBe("java-main:example.Alpha");
    expect(selected?.cwd).toBe("");
    expect(selected?.mavenReactorPath).toBe("services/alpha");
    expect(
      findMavenModuleRunConfiguration({
        configurations: resolved,
        defaultConfigurationId: "java-main:example.Beta",
        projectRelativePath: "services/missing",
        moduleRelativePath: ".",
        mode: "run",
      }),
    ).toBeNull();
  });

  test("ordinary Maven main entries do not fall back to Current File for Debug", () => {
    expect(
      findMavenModuleRunConfiguration({
        configurations: resolved,
        defaultConfigurationId: "current-file",
        projectRelativePath: "services/alpha",
        moduleRelativePath: ".",
        mode: "debug",
      }),
    ).toBeNull();
  });

  test("excludes both Current File identity and provider even with module ownership", () => {
    for (const candidate of [
      configuration({ id: "current-file", debugAdapter: "jdwp" }),
      configuration({ id: "user:file", provider: "java.current-file", debugAdapter: "jdwp" }),
    ]) {
      for (const mode of ["run", "debug"] as const) {
        expect(
          findMavenModuleRunConfiguration({
            configurations: [candidate],
            defaultConfigurationId: candidate.id,
            projectRelativePath: ".",
            moduleRelativePath: ".",
            mode,
          }),
        ).toBeNull();
      }
    }
  });

  test("does not treat a unique cwd match as proof of reactor ownership", () => {
    expect(
      findMavenModuleRunConfiguration({
        configurations: [
          configuration({ id: "user:unknown", cwd: "reactor", mavenReactorPath: undefined }),
        ],
        defaultConfigurationId: "user:unknown",
        projectRelativePath: "reactor",
        moduleRelativePath: ".",
        mode: "run",
      }),
    ).toBeNull();
  });

  test("matches a nested reactor module and keeps the configured service", () => {
    const service = configuration({
      id: "spring-boot.maven:backend",
      provider: "spring-boot.maven",
      execution: "service",
      cwd: "projects/demo",
      mavenReactorPath: "projects/demo",
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

  test("keeps detected ownership when the working directory is overridden", () => {
    const service = configuration({
      id: "quarkus.maven:api",
      provider: "quarkus.maven",
      execution: "service",
      cwd: "D:/custom-working-directory",
      mavenReactorPath: "reactor",
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
