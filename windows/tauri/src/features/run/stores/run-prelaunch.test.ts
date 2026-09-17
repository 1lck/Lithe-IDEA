import { describe, expect, mock, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { createRunStore, type RunStoreDependencies } from "./run.store";

const configuration: RunConfiguration = {
  id: "standalone",
  name: "Standalone",
  provider: "java.main",
  kindTitle: "Java Application",
  execution: "service",
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
  toolchains: { java: "project-jdk", maven: "project-maven" },
  source: "generated",
  disabled: false,
};

// Standalone Java compiles with javac before launching by class name, so JDK 8
// works (JEP 330 single-file launch is 11+). The store must run the pre-launch
// step, join the classpath with the Windows `;`, and prepend `-cp` to both the
// javac step and the main `java` invocation.
function standaloneDependencies(
  overrides: Partial<RunStoreDependencies> = {},
): { dependencies: RunStoreDependencies; executePreLaunchStep: ReturnType<typeof mock>; startRunProcess: ReturnType<typeof mock> } {
  const outputDir = ".lithe/run/classes/standalone";
  const createLaunchPlan = mock(async () => ({
    executable: { toolchain: "project-jdk" as const },
    arguments: ["Standalone"],
    workingDirectory: ".",
    classpath: [outputDir],
    preLaunchSteps: [
      {
        executable: { toolchain: "project-jdk" as const, tool: "javac" },
        arguments: ["-d", outputDir, "Standalone.java"],
      },
    ],
  }));
  const resolveRunLaunch = mock(async (args: { executable: { tool?: string | null } }) => ({
    executable:
      args.executable.tool === "javac" ? "C:/jdk8/bin/javac.exe" : "C:/jdk8/bin/java.exe",
    workingDirectory: "D:/work",
    environment: { JAVA_HOME: "C:/jdk8" },
  }));
  const executePreLaunchStep = mock(async () => ({ exitCode: 0, output: "compiled\n" }));
  const startRunProcess = mock(async () => undefined);
  const dependencies: RunStoreDependencies = {
    createLaunchPlan,
    mavenLaunchContextForWorkspace: mock(async () => null),
    resolveRunLaunch,
    executePreLaunchStep,
    saveWorkspaceBeforeLaunch: mock(async () => undefined),
    startRunProcess,
    stopRunProcess: mock(async () => undefined),
    ...overrides,
  };
  return { dependencies, executePreLaunchStep, startRunProcess };
}

describe("Standalone Java compile-then-run", () => {
  test("compiles with javac, then launches by class name with -cp", async () => {
    const { dependencies, executePreLaunchStep, startRunProcess } = standaloneDependencies();
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [configuration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    await store.getState().actions.runConfiguration(configuration.id);

    expect(executePreLaunchStep).toHaveBeenCalledWith({
      executable: "C:/jdk8/bin/javac.exe",
      arguments: ["-d", ".lithe/run/classes/standalone", "Standalone.java"],
      workingDirectory: "D:/work",
      environment: { JAVA_HOME: "C:/jdk8" },
    });
    expect(startRunProcess).toHaveBeenCalledWith(
      expect.objectContaining({
        executable: "C:/jdk8/bin/java.exe",
        arguments: ["-cp", ".lithe/run/classes/standalone", "Standalone"],
      }),
    );
  });

  test("aborts before launching when compilation fails", async () => {
    const { dependencies, startRunProcess } = standaloneDependencies({
      executePreLaunchStep: mock(async () => ({
        exitCode: 1,
        output: "Standalone.java:1: error: ';' expected\n",
      })),
    });
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [configuration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    await store.getState().actions.runConfiguration(configuration.id);

    expect(startRunProcess).not.toHaveBeenCalled();
    expect(store.getState().sessions).toEqual([
      expect.objectContaining({
        id: configuration.id,
        isRunning: false,
        exitCode: 1,
        output: expect.stringContaining("Compilation failed (exit code 1)."),
      }),
    ]);
  });
});
