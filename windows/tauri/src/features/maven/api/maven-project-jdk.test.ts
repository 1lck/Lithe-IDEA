import { expect, mock, test } from "bun:test";
import { resolveMavenLaunch } from "./maven-host-api";

test("Maven inherits the saved project JDK without saving a discovered or inherited path", async () => {
  const dependencies = {
    inspectRunConfiguration: mock(async () => ({
      status: "missing",
      toolchain: {
        java: { homePath: "C:/fixture/jdk-21" },
        maven: { javaHomePath: "" },
      },
    })),
    resolveRunLaunch: mock(async (args: { mavenJavaHomePath?: string }) => ({
      executable: "C:/fixture/maven/bin/mvn.cmd",
      workingDirectory: "C:/fixture/project",
      environment: { JAVA_HOME: args.mavenJavaHomePath ?? "" },
    })),
  };
  const context = { version: 1 as const, reactorPath: ".", profiles: [], skipTests: false };
  const plan = {
    version: 1 as const,
    executable: { toolchain: "project-maven" as const },
    arguments: [],
    workingDirectory: ".",
    configurationFingerprint: "fixture",
  };
  const inherited = await resolveMavenLaunch("C:/fixture/project", context, plan, dependencies);
  expect(inherited.environment.JAVA_HOME).toBe("C:/fixture/jdk-21");
  expect(dependencies.inspectRunConfiguration).toHaveBeenCalledWith("C:/fixture/project", false);
  dependencies.inspectRunConfiguration.mockClear();
  const overridden = await resolveMavenLaunch(
    "C:/fixture/project",
    { ...context, javaHomePath: "C:/fixture/maven-jdk" },
    plan,
    dependencies,
  );
  expect(overridden.environment.JAVA_HOME).toBe("C:/fixture/maven-jdk");
  expect(dependencies.inspectRunConfiguration).not.toHaveBeenCalled();
});
