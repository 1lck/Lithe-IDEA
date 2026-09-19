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
function standaloneDependencies(overrides: Partial<RunStoreDependencies> = {}): {
  dependencies: RunStoreDependencies;
  executePreLaunchStep: ReturnType<typeof mock>;
  startRunProcess: ReturnType<typeof mock>;
} {
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
    executable: args.executable.tool === "javac" ? "C:/jdk8/bin/javac.exe" : "C:/jdk8/bin/java.exe",
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
    prepareJavaRunLaunch: mock(async () => null),
    ...overrides,
  };
  return { dependencies, executePreLaunchStep, startRunProcess };
}

describe("Standalone Java compile-then-run", () => {
  test("passes JDT launch metadata to Core and joins classpath and module-path", async () => {
    const javaLaunch = {
      mainClass: "example.Main",
      projectName: "app",
      classPaths: ["D:/work/app/target/classes", "D:/repo/library.jar"],
      modulePaths: ["D:/work/app/target/modules"],
    };
    const createLaunchPlan = mock(async () => ({
      executable: { toolchain: "project-jdk" as const },
      arguments: ["example.Main"],
      workingDirectory: ".",
      classpath: javaLaunch.classPaths,
      modulepath: javaLaunch.modulePaths,
    }));
    const { dependencies, startRunProcess } = standaloneDependencies({
      createLaunchPlan,
      prepareJavaRunLaunch: mock(async () => javaLaunch),
    });
    const projectConfiguration = {
      ...configuration,
      sourcePath: "app/src/main/java/example/Main.java",
      mainClass: "example.Main",
      mavenReactorPath: ".",
    };
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [projectConfiguration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    await store.getState().actions.runConfiguration(projectConfiguration.id);

    expect(createLaunchPlan).toHaveBeenCalledWith(
      "D:/work",
      projectConfiguration.id,
      undefined,
      null,
      undefined,
      javaLaunch,
    );
    expect(startRunProcess).toHaveBeenCalledWith(
      expect.objectContaining({
        arguments: [
          "--module-path",
          "D:/work/app/target/modules",
          "-cp",
          "D:/work/app/target/classes;D:/repo/library.jar",
          "example.Main",
        ],
      }),
    );
  });

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

  test("merges the compiled-output classpath into an existing user -cp", async () => {
    const outputDir = ".lithe/run/classes/standalone";
    const { dependencies, startRunProcess } = standaloneDependencies({
      createLaunchPlan: mock(async () => ({
        executable: { toolchain: "project-jdk" as const },
        arguments: ["-cp", "libs/foo.jar", "Standalone"],
        workingDirectory: ".",
        classpath: [outputDir],
        preLaunchSteps: [
          {
            executable: { toolchain: "project-jdk" as const, tool: "javac" },
            arguments: ["-d", outputDir, "Standalone.java"],
          },
        ],
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

    // A second `-cp` would override the user's; the compiled dir is merged into
    // the same flag ahead of the user's entry so the fresh build still wins.
    expect(startRunProcess).toHaveBeenCalledWith(
      expect.objectContaining({
        arguments: ["-cp", `${outputDir};libs/foo.jar`, "Standalone"],
      }),
    );
  });

  test("echoes the javac command into the session output", async () => {
    const { dependencies } = standaloneDependencies();
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [configuration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    await store.getState().actions.runConfiguration(configuration.id);

    expect(store.getState().sessions[0].output).toContain(
      "$ javac.exe -d .lithe/run/classes/standalone Standalone.java",
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

// Issue #692: a cold multi-module build can wait minutes for JDT project
// updates, so the panel must show that preparation is in progress instead of
// staying blank until the JVM starts.
describe("Java project launch preparation feedback", () => {
  const projectConfiguration: RunConfiguration = {
    ...configuration,
    id: "ruoyi-admin",
    name: "ruoyi-admin",
    sourcePath: "ruoyi-admin/src/main/java/org/dromara/DromaraApplication.java",
    mainClass: "org.dromara.DromaraApplication",
    mavenReactorPath: ".",
  };
  const javaLaunch = {
    mainClass: "org.dromara.DromaraApplication",
    projectName: "ruoyi-admin",
    classPaths: ["D:/work/ruoyi-admin/target/classes"],
    modulePaths: [],
  };
  const projectPlan = {
    executable: { toolchain: "project-jdk" as const },
    arguments: ["org.dromara.DromaraApplication"],
    workingDirectory: ".",
    classpath: javaLaunch.classPaths,
  };

  function storeWith(
    runConfiguration: RunConfiguration,
    overrides: Partial<RunStoreDependencies>,
  ) {
    const { dependencies } = standaloneDependencies({
      createLaunchPlan: mock(async () => projectPlan),
      ...overrides,
    });
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [runConfiguration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });
    return store;
  }

  test("shows a service's preparation notice until its command line replaces it", async () => {
    let outputWhilePreparing: string | undefined;
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => {
        outputWhilePreparing = store.getState().sessions[0]?.output;
        return javaLaunch;
      }),
    });

    await store.getState().actions.runConfiguration(projectConfiguration.id);

    expect(outputWhilePreparing).toContain("waiting for the Java language service");
    expect(store.getState().selectedSessionId).toBe(projectConfiguration.id);
    const session = store.getState().sessions[0];
    expect(session.isRunning).toBe(true);
    expect(session.output).toStartWith("$ java.exe");
    expect(session.output).not.toContain("waiting for the Java language service");
  });

  test("keeps the notice above the Core build error when preparation fails", async () => {
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => {
        throw new Error("The Java project build was cancelled before it finished.");
      }),
    });

    await store.getState().actions.runConfiguration(projectConfiguration.id);

    const session = store.getState().sessions[0];
    expect(session).toEqual(
      expect.objectContaining({ id: projectConfiguration.id, isRunning: false, exitCode: 1 }),
    );
    expect(session.output).toMatch(
      /waiting for the Java language service[\s\S]*The Java project build was cancelled/,
    );
  });

  test("shows the notice in the primary panel for an application launch", async () => {
    const application: RunConfiguration = { ...projectConfiguration, execution: "application" };
    let primaryWhilePreparing: { output: string; title: string | null } | undefined;
    const store = storeWith(application, {
      prepareJavaRunLaunch: mock(async () => {
        const state = store.getState();
        primaryWhilePreparing = { output: state.primaryOutput, title: state.primaryTitle };
        return javaLaunch;
      }),
    });

    await store.getState().actions.runConfiguration(application.id);

    expect(primaryWhilePreparing?.title).toBe("ruoyi-admin");
    expect(primaryWhilePreparing?.output).toContain("waiting for the Java language service");
    expect(store.getState().primaryOutput).toStartWith("$ java.exe");
  });

  test("does not show the notice for standalone Java compiled with javac", async () => {
    let outputWhilePreparing: string | undefined = "not called";
    const { dependencies } = standaloneDependencies({
      prepareJavaRunLaunch: mock(async () => {
        outputWhilePreparing = store.getState().sessions[0]?.output;
        return null;
      }),
    });
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [configuration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    await store.getState().actions.runConfiguration(configuration.id);

    expect(outputWhilePreparing).toBeUndefined();
  });
});
