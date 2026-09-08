import { beforeEach, describe, expect, mock, test } from "bun:test";

const executeCore = mock(async () => ({
  id: "request",
  ok: true as const,
  data: null as unknown,
}));
const cancelCoreOperation = mock(async () => true);

mock.module("@/core/lithe-core-client", () => ({ executeCore, cancelCoreOperation }));

const { createMavenLaunchPlan, discoverJavaTestMethods, scanMavenProject } =
  await import("./maven-core-api");

beforeEach(() => {
  executeCore.mockClear();
});

describe("Maven Core API", () => {
  test("scans with the visible workspace-relative paths", async () => {
    await scanMavenProject("D:/work", ["reactor/pom.xml", "reactor/app/src/App.java"]);

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "maven.scan",
        payload: {
          root: "D:/work",
          paths: ["reactor/pom.xml", "reactor/app/src/App.java"],
        },
      }),
    );
  });

  test("forwards the complete context without assembling Maven arguments", async () => {
    const context = {
      version: 1 as const,
      reactorPath: "reactor",
      profiles: ["dev", "qa"],
      settingsPath: "C:/Users/example/.m2/settings.xml",
      skipTests: true,
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    };

    await createMavenLaunchPlan("D:/work", context, ["verify"], "app");

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "maven.launchPlan",
        payload: {
          root: "D:/work",
          context,
          module: "app",
          goals: ["verify"],
        },
      }),
    );
  });

  test("discovers Java test methods through the shared syntax command", async () => {
    executeCore.mockResolvedValueOnce({
      id: "request",
      ok: true as const,
      data: {
        testMethods: [{ name: "inline", line: 2, endLine: 2 }],
      },
    });

    await expect(discoverJavaTestMethods("class AppTest {}")).resolves.toEqual([
      { name: "inline", line: 2, endLine: 2 },
    ]);
    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "java.structure",
        payload: { source: "class AppTest {}" },
      }),
    );
  });
});
