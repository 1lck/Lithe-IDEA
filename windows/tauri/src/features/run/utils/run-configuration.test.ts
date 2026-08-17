import { describe, expect, test } from "bun:test";
import {
  configurationsForExecution,
  defaultGeneratedConfigurationId,
  isBlockingToolchainDiagnostic,
  mapCoreConfiguration,
  mergeLaunchEnvironment,
  workspaceRelativePath,
} from "./run-configuration";

describe("run configuration mapping", () => {
  test("maps a Spring Boot service and keeps the main class", () => {
    const configuration = mapCoreConfiguration({
      id: "spring-boot.maven:demo",
      name: "demo",
      provider: "spring-boot.maven",
      execution: "service",
      source: "generated",
      extensions: {
        maven: { module: ".", mainClass: "com.example.demo.DemoApplication" },
      },
    });

    expect(configuration.kindTitle).toBe("Spring Boot");
    expect(configuration.execution).toBe("service");
    expect(configuration.mainClass).toBe("com.example.demo.DemoApplication");
    expect(configuration.modulePath).toBeUndefined();
  });

  test("groups runnable configurations and hides Current File", () => {
    const configurations = [
      mapCoreConfiguration({
        id: "current-file",
        name: "Current File",
        provider: "java.current-file",
        execution: "application",
      }),
      mapCoreConfiguration({
        id: "java-main:com.example.demo.DemoApplication",
        name: "DemoApplication",
        provider: "java.main",
        execution: "application",
      }),
      mapCoreConfiguration({
        id: "spring-boot.maven:demo",
        name: "demo",
        provider: "spring-boot.maven",
        execution: "service",
      }),
    ];

    expect(configurationsForExecution(configurations, "service")).toHaveLength(1);
    expect(configurationsForExecution(configurations, "application").map((item) => item.id)).toEqual([
      "java-main:com.example.demo.DemoApplication",
    ]);
  });

  test("treats missing and mismatched toolchains as blocking", () => {
    expect(isBlockingToolchainDiagnostic({ code: "missingToolchain", message: "No JDK" })).toBe(true);
    expect(isBlockingToolchainDiagnostic({ code: "staleFingerprint", message: "changed" })).toBe(false);
  });

  test("prefers a framework service as the generated default", () => {
    expect(
      defaultGeneratedConfigurationId({
        configurations: [
          { id: "current-file", provider: "java.current-file" },
          { id: "spring-boot.maven:demo", provider: "spring-boot.maven" },
        ],
      }),
    ).toBe("spring-boot.maven:demo");
  });

  test("converts workspace paths to core-relative identifiers", () => {
    expect(
      workspaceRelativePath("D:\\work\\demo", "D:\\work\\demo\\src\\main\\java\\App.java"),
    ).toBe("src/main/java/App.java");
  });

  test("merges user env with toolchain-derived launch environment", () => {
    expect(
      mergeLaunchEnvironment(
        { APP_ENV: "dev" },
        {
          env: { DEBUG: "true" },
          environment: { JAVA_HOME: { toolchain: "project-jdk", property: "home" } },
        },
      ),
    ).toEqual({
      APP_ENV: "dev",
      DEBUG: "true",
      JAVA_HOME: { toolchain: "project-jdk", property: "home" },
    });
  });
});
