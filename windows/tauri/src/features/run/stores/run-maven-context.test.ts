import { describe, expect, mock, test } from "bun:test";
import type { MavenLaunchContext } from "@/features/maven/types/maven.types";
import type { RunConfiguration } from "../types/run.types";
import { createRunStore, type RunStoreDependencies } from "./run.store";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

const mavenContext: MavenLaunchContext = {
  version: 1,
  reactorPath: "reactor",
  profiles: ["dev"],
  settingsPath: "C:/Users/example/.m2/settings.xml",
  skipTests: true,
  mavenExecutablePath: "D:/Tools/apache-maven",
  javaHomePath: "C:/Java/jdk-21",
};

const configuration: RunConfiguration = {
  id: "spring",
  name: "Spring Boot",
  provider: "spring-boot.maven",
  kindTitle: "Spring Boot",
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

describe("Maven-backed Run context", () => {
  test("waits for the workspace Maven load before creating the launch plan", async () => {
    const pendingContext = deferred<MavenLaunchContext | null>();
    const events: string[] = [];
    const createLaunchPlan = mock(
      async (...args: Parameters<RunStoreDependencies["createLaunchPlan"]>) => {
        events.push("plan-created");
        expect(args[3]).toEqual(mavenContext);
        return {
          executable: { toolchain: "project-maven" },
          arguments: ["-B", "spring-boot:run"],
          workingDirectory: "reactor",
        };
      },
    );
    const mavenLaunchContextForWorkspace = mock(async () => {
      events.push("context-started");
      return pendingContext.promise;
    });
    const resolveRunLaunch = mock(async () => ({
      executable: "D:/Tools/apache-maven/bin/mvn.cmd",
      workingDirectory: "D:/work/reactor",
      environment: {},
    }));
    const startRunProcess = mock(async () => undefined);
    const stopRunProcess = mock(async () => undefined);
    const dependencies: RunStoreDependencies = {
      createLaunchPlan,
      mavenLaunchContextForWorkspace,
      resolveRunLaunch,
      startRunProcess,
      stopRunProcess,
    };
    const store = createRunStore("workspace", dependencies);
    store.setState({
      root: "D:/work",
      configurations: [configuration],
      diagnostics: [],
      effectiveRuntimeExecutablePaths: {},
    });

    const run = store.getState().actions.runConfiguration(configuration.id);
    try {
      await Promise.resolve();
      await Promise.resolve();
      expect(events).toEqual(["context-started"]);
      expect(createLaunchPlan).not.toHaveBeenCalled();
    } finally {
      pendingContext.resolve(mavenContext);
      await run;
    }

    expect(mavenLaunchContextForWorkspace).toHaveBeenCalledWith("D:/work", [], "workspace");
    expect(createLaunchPlan).toHaveBeenCalledWith("D:/work", "spring", undefined, mavenContext);
    expect(resolveRunLaunch).toHaveBeenCalledWith(
      expect.objectContaining({
        mavenExecutablePath: "D:/Tools/apache-maven",
        mavenJavaHomePath: "C:/Java/jdk-21",
      }),
    );
  });
});
