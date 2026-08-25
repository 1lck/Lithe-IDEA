import { beforeEach, describe, expect, mock, test } from "bun:test";

const executeCore = mock(async () => ({
  id: "request",
  ok: true as const,
  data: { document: "{}" },
}));

mock.module("@/core/lithe-core-client", () => ({ executeCore }));

const { updateGlobalToolchain, updateRunOptions } = await import("./run-core-api");

beforeEach(() => {
  executeCore.mockClear();
});

describe("updateRunOptions", () => {
  test("sends project-relative working directory and toolchain paths in project scope", async () => {
    await updateRunOptions("D:/fixture/project", "plain-java", "project", {
      javaHomePath: "D:\\fixture\\project\\toolchains\\jdk",
      mavenExecutablePath: "D:/fixture/project/toolchains/maven/bin/mvn.cmd",
      mavenJavaHomePath: "D:/fixture/project/toolchains/maven-jdk",
      workingDirectoryPath: "D:/fixture/project/app",
      vmArguments: "-Xmx2g",
      programArguments: "--dev",
      environment: { APP_ENV: "dev" },
    });

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "runConfig.updateOptions",
        payload: expect.objectContaining({
          root: "D:/fixture/project",
          scope: "project",
          configurationId: "plain-java",
          workingDirectory: "app",
          jvmArguments: "-Xmx2g",
          arguments: "--dev",
          environment: { APP_ENV: "dev" },
          mavenProfiles: [],
          javaHomePath: "toolchains/jdk",
          mavenExecutablePath: "toolchains/maven/bin/mvn.cmd",
          mavenJavaHomePath: "toolchains/maven-jdk",
        }),
      }),
    );
  });

  test("keeps working directory and toolchain paths absolute in local scope", async () => {
    await updateRunOptions("D:/fixture/project", "plain-java", "local", {
      javaHomePath: "C:/Program Files/Java/jdk-21",
      mavenExecutablePath: "D:/Tools/apache-maven",
      mavenJavaHomePath: "C:/Program Files/Java/jdk-17",
      workingDirectoryPath: "D:/fixture/project/app",
      vmArguments: "",
      programArguments: "",
      environment: {},
    });

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        payload: expect.objectContaining({
          workingDirectory: "D:/fixture/project/app",
          javaHomePath: "C:/Program Files/Java/jdk-21",
          mavenExecutablePath: "D:/Tools/apache-maven",
          mavenJavaHomePath: "C:/Program Files/Java/jdk-17",
        }),
      }),
    );
  });

  test("rejects a project path outside the workspace", () => {
    expect(() =>
      updateRunOptions("D:/fixture/project", "plain-java", "project", {
        javaHomePath: "",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        workingDirectoryPath: "E:/outside",
        vmArguments: "",
        programArguments: "",
        environment: {},
      }),
    ).toThrow("Project paths must stay inside the workspace.");
    expect(executeCore).not.toHaveBeenCalled();
  });

  test("rejects a project toolchain path outside the workspace", () => {
    expect(() =>
      updateRunOptions("D:/fixture/project", "plain-java", "project", {
        javaHomePath: "C:/Program Files/Java/jdk-21",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        workingDirectoryPath: "",
        vmArguments: "",
        programArguments: "",
        environment: {},
      }),
    ).toThrow("Project paths must stay inside the workspace.");
    expect(executeCore).not.toHaveBeenCalled();
  });
});

describe("updateGlobalToolchain", () => {
  test("writes the global toolchain into the local layer", async () => {
    await updateGlobalToolchain("D:/fixture/project", {
      javaHomePath: "C:/Program Files/Java/jdk-21",
      mavenExecutablePath: "D:/Tools/apache-maven/bin/mvn.cmd",
      mavenJavaHomePath: "C:/Program Files/Java/jdk-17",
    });

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "runConfig.updateOptions",
        payload: {
          root: "D:/fixture/project",
          scope: "local",
          configurationId: "toolchain",
          toolchain: {
            javaHomePath: "C:/Program Files/Java/jdk-21",
            mavenExecutablePath: "D:/Tools/apache-maven/bin/mvn.cmd",
            mavenJavaHomePath: "C:/Program Files/Java/jdk-17",
          },
        },
      }),
    );
  });
});
