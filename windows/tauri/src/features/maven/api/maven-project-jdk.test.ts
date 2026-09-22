import { expect, mock, spyOn, test } from "bun:test";
import { resolveMavenLaunch } from "./maven-host-api";

test("broken Run documents do not prevent independent Maven goals from using host defaults", async () => {
  const warning = spyOn(console, "warn").mockImplementation(() => {});
  try {
    const resolveRunLaunch = mock(async (args: { mavenJavaHomePath?: string }) => ({
      executable: "C:/fixture/maven/bin/mvn.cmd",
      workingDirectory: "C:/fixture/project",
      environment: { JAVA_HOME: args.mavenJavaHomePath || "C:/fixture/host-jdk" },
    }));
    const result = await resolveMavenLaunch(
      "C:/fixture/project",
      {
        version: 1,
        reactorPath: ".",
        profiles: [],
        skipTests: false,
      },
      {
        version: 1,
        executable: { toolchain: "project-maven" },
        arguments: [],
        workingDirectory: ".",
        configurationFingerprint: "fixture",
      },
      {
        inspectRunConfiguration: async () => {
          throw new Error("private-path: malformed generated.json");
        },
        resolveRunLaunch,
      },
    );
    expect(result.environment.JAVA_HOME).toBe("C:/fixture/host-jdk");
    expect(resolveRunLaunch).toHaveBeenCalledTimes(1);
    expect(warning).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(warning.mock.calls)).not.toContain("private-path");
  } finally {
    warning.mockRestore();
  }
});

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
