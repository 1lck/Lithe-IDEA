import { describe, expect, mock, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { createRunStore, type RunStoreDependencies } from "./run.store";

const configuration: RunConfiguration = {
  id: "standalone",
  name: "Standalone",
  provider: "java.main",
  kindTitle: "Java Application",
  category: "project" as const,
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
    seedMavenLocalConfiguration: () => undefined,
    prepareJavaRunLaunch: mock(async () => null),
    javaBuildFailurePolicyForWorkspace: () => "ask",
    setJavaBuildFailurePolicy: mock(() => undefined),
    rebuildJavaIndexForWorkspace: mock(async () => undefined),
    presentJavaLaunchDecision: mock(() => undefined),
    ...overrides,
  };
  return { dependencies, executePreLaunchStep, startRunProcess };
}

describe("Standalone Java compile-then-run", () => {
  test("stopping resource processing invalidates the execution before JVM launch", async () => {
    let release = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    let reached = () => {};
    const started = new Promise<void>((resolve) => {
      reached = resolve;
    });
    const stopRunProcess = mock(async () => undefined);
    const { dependencies, startRunProcess } = standaloneDependencies({
      executePreLaunchStep: async () => {
        reached();
        await gate;
        return { exitCode: 0, output: "" };
      },
      stopRunProcess,
    });
    const store = createRunStore("resource-stop", dependencies);
    store.setState({ root: "D:/work", configurations: [configuration], diagnostics: [] });
    const launch = store.getState().actions.runConfiguration(configuration.id);
    try {
      await started;
      const executionId = store.getState().sessions[0].executionId;
      await store.getState().actions.stop(configuration.id);
      expect(stopRunProcess).toHaveBeenCalledWith(configuration.id, executionId);
    } finally {
      release();
      await launch;
      await store.getState().actions.stop(configuration.id);
    }
    expect(startRunProcess).not.toHaveBeenCalled();
  });
  for (const provider of ["java.main", "spring-boot.maven"] as const) {
    for (const exitCode of [0, 1]) {
      test(`${provider} synchronizes Maven resources before launch (exit ${exitCode})`, async () => {
        const events: string[] = [];
        const resourceArguments = ["-B", "-ntp", "-pl", "app", "-am", "resources:resources"];
        const { dependencies } = standaloneDependencies({
          saveWorkspaceBeforeLaunch: async () => {
            events.push("save");
          },
          prepareJavaRunLaunch: async () => {
            events.push("build");
            return {
              kind: "ready",
              target: {
                mainClass: "example.Main",
                projectName: "app",
                modulePaths: [],
                classPaths: ["D:/work/app/target/classes"],
              },
            };
          },
          createLaunchPlan: async () => ({
            executable: { toolchain: "project-jdk" },
            arguments: ["example.Main"],
            workingDirectory: "custom-run",
            classpath: ["D:/work/app/target/classes"],
            preLaunchSteps: [
              {
                executable: { toolchain: "project-maven" },
                arguments: resourceArguments,
                workingDirectory: "app",
              },
            ],
          }),
          resolveRunLaunch: async (request) => {
            if (request.executable.toolchain === "project-maven") {
              // The resource step resolves Maven from the reactor (and finds a
              // project wrapper there) instead of the overridden cwd.
              expect(request.workingDirectory).toBe("app");
              return { executable: "mvn.cmd", workingDirectory: "D:/work/app", environment: {} };
            }
            expect(request.workingDirectory).toBe("custom-run");
            return {
              executable: "java.exe",
              workingDirectory: "D:/work/custom-run",
              environment: {},
            };
          },
          executePreLaunchStep: async (request) => {
            expect(request.executable).toBe("mvn.cmd");
            expect(request.arguments).toEqual(resourceArguments);
            expect(request.workingDirectory).toBe("D:/work/app");
            events.push("resources");
            return { exitCode, output: "resource processing output\n" };
          },
          startRunProcess: async () => {
            events.push("launch");
          },
        });
        const store = createRunStore(`resource-sync-${provider}-${exitCode}`, dependencies);
        store.setState({
          root: "D:/work",
          configurations: [{ ...configuration, provider }],
          diagnostics: [],
        });
        try {
          const result = await store.getState().actions.runConfiguration(configuration.id);
          expect(result).toBe(exitCode === 0 ? configuration.id : null);
          expect(events).toEqual(
            exitCode === 0
              ? ["save", "build", "resources", "launch"]
              : ["save", "build", "resources"],
          );
          expect(store.getState().sessions[0].output).toContain("resource processing output");
          if (exitCode !== 0) {
            expect(store.getState().sessions[0].output).toContain(
              "Pre-launch step failed (exit code 1).",
            );
            expect(store.getState().sessions[0].isRunning).toBe(false);
          }
        } finally {
          await store.getState().actions.stop(configuration.id);
        }
      });
    }
  }
  test("service update keeps its launch target and blocks duplicate updates", async () => {
    const target = {
      mainClass: "example.Main",
      projectName: "app",
      modulePaths: [],
      classPaths: ["D:/work/classes", "D:/repo/spring-boot-devtools-3.5.0.jar"],
    };
    let release: () => void = () => {};
    const buildGate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const build = mock(async () => {
      await buildGate;
    });
    const { dependencies } = standaloneDependencies({
      prepareJavaRunLaunch: async () => ({ kind: "ready", target }),
      buildJavaServiceUpdate: build,
    });
    const store = createRunStore("workspace-hcr", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [{ ...configuration, sourcePath: "src/Main.java" }],
      diagnostics: [],
    });
    await store.getState().actions.runConfiguration(configuration.id);
    const update = store.getState().actions.updateService(configuration.id);
    try {
      // save() resolves in one known microtask; compilation then waits on our gate.
      await Promise.resolve();
      store.setState({ configurations: [{ ...configuration, sourcePath: "src/Other.java" }] });
      await store.getState().actions.updateService(configuration.id);
      expect(build).toHaveBeenCalledTimes(1);
      expect(build).toHaveBeenCalledWith(
        "D:/work",
        expect.objectContaining({ sourcePath: "src/Main.java", target }),
      );
      // A stop releases the visible session without waiting for the compiler.
      await store.getState().actions.stop(configuration.id);
    } finally {
      release();
      await update;
      await store.getState().actions.stop(configuration.id);
    }
    expect(store.getState().serviceUpdates[configuration.id].message).not.toContain(
      "Compilation finished",
    );
    expect(store.getState().serviceUpdates[configuration.id].pending).toBe(false);
  });
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
      prepareJavaRunLaunch: mock(async () => ({ kind: "ready" as const, target: javaLaunch })),
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
        executionId: store.getState().sessions[0].executionId,
        arguments: [
          "--module-path",
          "D:/work/app/target/modules",
          "-cp",
          "D:/work/app/target/classes;D:/repo/library.jar",
          "example.Main",
        ],
      }),
    );
    expect(store.getState().sessions[0].executionId).toEqual(expect.any(String));
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
      sessionId: configuration.id,
      executionId: store.getState().sessions[0].executionId,
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
        output: expect.stringContaining("Pre-launch step failed (exit code 1)."),
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
  const failedPreparation = {
    kind: "buildFailed" as const,
    target: javaLaunch,
    failure: {
      code: "javaBuildCompilationErrors" as const,
      message: "The Java project has compilation errors.",
      report: {
        markerScope: "launchTarget" as const,
        builderFailedEarlier: true,
        elapsedMilliseconds: 7,
        recovery: "rebuildJavaIndex" as const,
      },
    },
  };

  function storeWith(runConfiguration: RunConfiguration, overrides: Partial<RunStoreDependencies>) {
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
        return { kind: "ready" as const, target: javaLaunch };
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
        return { kind: "ready" as const, target: javaLaunch };
      }),
    });

    await store.getState().actions.runConfiguration(application.id);

    expect(store.getState().primaryExecutionId).toEqual(expect.any(String));
    expect(store.getState().primaryConfigurationId).toBe(application.id);
    expect(store.getState().primaryPreparing).toBe(false);
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

  test("continues the same launch after one failed build without rebuilding", async () => {
    const prepare = mock(async () => failedPreparation);
    const presentDecision = mock(() => undefined);
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: prepare,
      presentJavaLaunchDecision: presentDecision,
    });
    let observedMessage: string | undefined;
    const unsubscribe = store.subscribe((state) => {
      const decision = state.javaLaunchDecisions[projectConfiguration.id];
      if (!decision || observedMessage) return;
      observedMessage = decision.failure.message;
      state.actions.continueJavaLaunch(projectConfiguration.id, decision.decisionId, false);
    });

    try {
      expect(await store.getState().actions.runConfiguration(projectConfiguration.id)).toBe(
        projectConfiguration.id,
      );
    } finally {
      unsubscribe();
    }

    expect(observedMessage).toContain("compilation errors");
    expect(prepare).toHaveBeenCalledTimes(1);
    expect(presentDecision).toHaveBeenCalledWith("workspace");
    expect(store.getState().sessions[0].isRunning).toBe(true);
    expect(store.getState().sessions[0].output).toContain(
      "Continuing with the Java output currently available on disk.",
    );
    expect(store.getState().javaLaunchDecisions).toEqual({});
  });

  test("a same-project reload keeps the launch waiting for its build decision", async () => {
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => failedPreparation),
      inspectRunConfiguration: mock(async () => ({ status: "missing" })),
    });
    let reloaded = false;
    let decisionAfterReload: string | undefined;
    const unsubscribe = store.subscribe((state) => {
      const decision = state.javaLaunchDecisions[projectConfiguration.id];
      if (!decision || reloaded) return;
      reloaded = true;
      // Saving project defaults reloads the project while the decision is open.
      // Continuing afterwards is a no-op if the reload already cancelled the
      // launch, so a regression fails the assertions instead of hanging.
      void state.actions.loadProject("D:/work").then(() => {
        decisionAfterReload =
          store.getState().javaLaunchDecisions[projectConfiguration.id]?.decisionId;
        store
          .getState()
          .actions.continueJavaLaunch(projectConfiguration.id, decision.decisionId, false);
      });
    });

    try {
      expect(await store.getState().actions.runConfiguration(projectConfiguration.id)).toBe(
        projectConfiguration.id,
      );
    } finally {
      unsubscribe();
    }

    expect(reloaded).toBe(true);
    expect(decisionAfterReload).toBeDefined();
    expect(store.getState().sessions[0].isRunning).toBe(true);
  });

  test("remembers Always Continue for the workspace", async () => {
    const setPolicy = mock(() => undefined);
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => failedPreparation),
      setJavaBuildFailurePolicy: setPolicy,
    });
    const unsubscribe = store.subscribe((state) => {
      const decision = state.javaLaunchDecisions[projectConfiguration.id];
      if (decision) {
        state.actions.continueJavaLaunch(projectConfiguration.id, decision.decisionId, true);
      }
    });

    try {
      await store.getState().actions.runConfiguration(projectConfiguration.id);
    } finally {
      unsubscribe();
    }

    expect(setPolicy).toHaveBeenCalledWith("D:/work", "alwaysProceed");
  });

  test("an Always Continue workspace never pauses for the same terminal failure", async () => {
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => failedPreparation),
      javaBuildFailurePolicyForWorkspace: () => "alwaysProceed",
    });

    expect(await store.getState().actions.runConfiguration(projectConfiguration.id)).toBe(
      projectConfiguration.id,
    );
    expect(store.getState().javaLaunchDecisions).toEqual({});
    expect(store.getState().sessions[0].isRunning).toBe(true);
  });

  test("cancel leaves the failed launch stopped", async () => {
    const { dependencies, startRunProcess } = standaloneDependencies({
      createLaunchPlan: mock(async () => projectPlan),
      prepareJavaRunLaunch: mock(async () => failedPreparation),
    });
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [projectConfiguration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });
    const unsubscribe = store.subscribe((state) => {
      const decision = state.javaLaunchDecisions[projectConfiguration.id];
      if (decision) {
        state.actions.cancelJavaLaunch(projectConfiguration.id, decision.decisionId);
      }
    });

    try {
      expect(await store.getState().actions.runConfiguration(projectConfiguration.id)).toBeNull();
    } finally {
      unsubscribe();
    }

    expect(startRunProcess).not.toHaveBeenCalled();
    expect(store.getState().sessions[0].isRunning).toBe(false);
    expect(store.getState().sessions[0].isPreparing).toBe(false);
  });

  test("rebuild index cancels the pending launch and clears only this workspace", async () => {
    const rebuild = mock(async () => undefined);
    const store = storeWith(projectConfiguration, {
      prepareJavaRunLaunch: mock(async () => failedPreparation),
      rebuildJavaIndexForWorkspace: rebuild,
    });
    let recovery: Promise<void> | undefined;
    const unsubscribe = store.subscribe((state) => {
      const decision = state.javaLaunchDecisions[projectConfiguration.id];
      if (decision && !recovery) {
        recovery = state.actions.rebuildJavaIndex(projectConfiguration.id, decision.decisionId);
      }
    });

    try {
      expect(await store.getState().actions.runConfiguration(projectConfiguration.id)).toBeNull();
      await recovery;
    } finally {
      unsubscribe();
    }

    expect(rebuild).toHaveBeenCalledWith("D:/work");
    expect(store.getState().sessions[0].output).toContain("Java index cleared");
  });
});

// The Tauri host rejects with the plain string its Rust handler returned, so
// the panel used to replace every launch failure with a generic sentence.
describe("Java launch failure reporting", () => {
  test("shows the host's reason when the rejection is a string", async () => {
    const { dependencies } = standaloneDependencies({
      startRunProcess: mock(async () => {
        throw "Unable to start process: The filename or extension is too long. (os error 206)";
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

    const session = store.getState().sessions[0];
    expect(session.output).toContain("os error 206");
    expect(session.output).not.toContain("Unable to start the run configuration.");
    expect(session.exitCode).toBe(1);
  });

  test("falls back to a readable sentence when the host reports nothing", async () => {
    const { dependencies } = standaloneDependencies({
      startRunProcess: mock(async () => {
        throw "";
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

    expect(store.getState().sessions[0].output).toContain("Unable to start the run configuration.");
  });
});
