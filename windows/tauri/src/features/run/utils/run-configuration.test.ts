import { describe, expect, test } from "bun:test";
import {
  configurationsForExecution,
  blockingToolchainDiagnosticForConfiguration,
  configurationOverrides,
  configurationUsesMaven,
  defaultGeneratedConfigurationId,
  effectiveRuntimeExecutablePaths,
  isBlockingToolchainDiagnostic,
  mapCoreConfiguration,
  mergeLaunchEnvironment,
  projectScopedPath,
  selectedToolchainCandidates,
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
    expect(projectScopedPath("D:/work/demo", "D:/other/output")).toBeUndefined();
  });

  test("selects a probed custom toolchain instead of an unrelated automatic runtime", () => {
    const candidates = selectedToolchainCandidates(
      {
        java: [
          { homePath: "C:/Java/automatic", version: "17", vendor: "Auto" },
          { homePath: "D:\\SDKs\\custom", version: "21", vendor: "Custom" },
        ],
        maven: [],
        runtimes: [],
      },
      {
        javaHomePath: "d:/sdks/custom/",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        runtimeExecutablePaths: {},
      },
    );

    expect(candidates).toEqual([
      { id: "project-jdk", type: "java", version: "21", vendor: "Custom" },
    ]);
  });

  test("matches a selected Maven Home to its discovered bin executable", () => {
    const candidates = selectedToolchainCandidates(
      {
        java: [],
        maven: [
          { executablePath: "D:\\Tools\\apache-maven\\bin\\mvn.cmd", version: "3.9.9" },
        ],
        runtimes: [],
      },
      {
        javaHomePath: "",
        mavenExecutablePath: "d:/tools/apache-maven/",
        mavenJavaHomePath: "",
        runtimeExecutablePaths: {},
      },
    );

    expect(candidates).toEqual([
      { id: "project-maven", type: "maven", version: "3.9.9", vendor: "" },
    ]);
  });

  test("shows Maven settings from the configuration requirement without discovery", () => {
    expect(configurationUsesMaven({ toolchains: { java: "project-jdk", maven: "project-maven" } })).toBe(true);
    expect(configurationUsesMaven({ toolchains: { java: "project-jdk" } })).toBe(false);
  });

  test("removes inherited toolchain values and keeps configuration overrides", () => {
    const defaults = {
      javaHomePath: "C:/SDKs/jdk-21",
      mavenExecutablePath: "C:/SDKs/maven",
      mavenJavaHomePath: "C:/SDKs/maven-jdk",
      runtimeExecutablePaths: {},
    };
    const options = {
      ...defaults,
      javaHomePath: "c:\\sdks\\jdk-21\\",
      mavenJavaHomePath: "D:/SDKs/service-jdk",
      workingDirectoryPath: "app",
      vmArguments: "-Xmx2g",
      programArguments: "--dev",
      environment: { APP_ENV: "dev" },
    };

    expect(configurationOverrides(options, defaults)).toEqual({
      ...options,
      javaHomePath: "",
      mavenExecutablePath: "",
      mavenJavaHomePath: "D:/SDKs/service-jdk",
    });
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

  test("blocks only the configuration named by a toolchain diagnostic", () => {
    const diagnostics = [
      {
        id: "npm.script:web/dev",
        code: "missingToolchain",
        message: "No local node toolchain is selected",
      },
    ];

    expect(
      blockingToolchainDiagnosticForConfiguration(diagnostics, "spring-boot.maven:backend"),
    ).toBeUndefined();
    expect(
      blockingToolchainDiagnosticForConfiguration(diagnostics, "npm.script:web/dev")?.message,
    ).toContain("node");
    expect(
      blockingToolchainDiagnosticForConfiguration(
        [{ code: "missingToolchain", message: "Project toolchain is missing" }],
        "spring-boot.maven:backend",
      ),
    ).toBeDefined();
  });

  test("selects the configured generic runtime candidate", () => {
    const candidates = selectedToolchainCandidates(
      {
        java: [],
        maven: [],
        runtimes: [
          {
            id: "project-node",
            type: "node",
            executablePath: "C:/Program Files/nodejs/node.exe",
            version: "22.5.1",
            vendor: "Node.js",
          },
          {
            id: "project-node",
            type: "node",
            executablePath: "D:/runtimes/node.exe",
            version: "20.18.0",
            vendor: "Node.js",
          },
        ],
      },
      {
        javaHomePath: "",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        runtimeExecutablePaths: { "project-node": "d:\\runtimes\\node.exe" },
      },
    );

    expect(candidates).toEqual([
      { id: "project-node", type: "node", version: "20.18.0", vendor: "Node.js" },
    ]);
  });

  test("uses the same automatic runtime path for validation and launch", () => {
    const runtimes = [
      {
        id: "project-node",
        type: "node",
        executablePath: "C:/Program Files/nodejs/node.exe",
        version: "22.5.1",
        vendor: "Node.js",
      },
      {
        id: "project-node",
        type: "node",
        executablePath: "D:/path-node/node.exe",
        version: "18.20.4",
        vendor: "Node.js",
      },
    ];
    const effectivePaths = effectiveRuntimeExecutablePaths(runtimes, {});
    const selected = {
      javaHomePath: "",
      mavenExecutablePath: "",
      mavenJavaHomePath: "",
      runtimeExecutablePaths: effectivePaths,
    };

    expect(effectivePaths).toEqual({
      "project-node": "C:/Program Files/nodejs/node.exe",
    });
    expect(selectedToolchainCandidates({ java: [], maven: [], runtimes }, selected)).toEqual([
      { id: "project-node", type: "node", version: "22.5.1", vendor: "Node.js" },
    ]);
  });
});
