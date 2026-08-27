import { beforeEach, describe, expect, mock, test } from "bun:test";

const executeCore = mock(async () => ({
  id: "request",
  ok: true as const,
  data: { document: "{}" },
}));

mock.module("@/core/lithe-core-client", () => ({ executeCore }));

const { saveRunConfigurationEditorChanges } = await import("./run-core-api");

const emptyToolchain = {
  javaHomePath: "",
  mavenExecutablePath: "",
  mavenJavaHomePath: "",
  runtimeExecutablePaths: {},
};

beforeEach(() => {
  executeCore.mockClear();
});

describe("saveRunConfigurationEditorChanges", () => {
  test("sends project-relative working directory and toolchain paths in project scope", async () => {
    await saveRunConfigurationEditorChanges(
      "D:/fixture/project",
      "plain-java",
      "project",
      {
        javaHomePath: "D:\\fixture\\project\\toolchains\\jdk",
        mavenExecutablePath: "D:/fixture/project/toolchains/maven/bin/mvn.cmd",
        mavenJavaHomePath: "D:/fixture/project/toolchains/maven-jdk",
        workingDirectoryPath: "D:/fixture/project/app",
        vmArguments: "-Xmx2g",
        programArguments: "--dev",
        environment: { APP_ENV: "dev" },
      },
      emptyToolchain,
    );

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "runConfig.saveEditorChanges",
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
    await saveRunConfigurationEditorChanges(
      "D:/fixture/project",
      "plain-java",
      "local",
      {
        javaHomePath: "C:/Program Files/Java/jdk-21",
        mavenExecutablePath: "D:/Tools/apache-maven",
        mavenJavaHomePath: "C:/Program Files/Java/jdk-17",
        workingDirectoryPath: "D:/fixture/project/app",
        vmArguments: "",
        programArguments: "",
        environment: {},
      },
      emptyToolchain,
    );

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
      saveRunConfigurationEditorChanges(
        "D:/fixture/project",
        "plain-java",
        "project",
        {
          javaHomePath: "",
          mavenExecutablePath: "",
          mavenJavaHomePath: "",
          workingDirectoryPath: "E:/outside",
          vmArguments: "",
          programArguments: "",
          environment: {},
        },
        emptyToolchain,
      ),
    ).toThrow("Project paths must stay inside the workspace.");
    expect(executeCore).not.toHaveBeenCalled();
  });

  test("rejects a project toolchain path outside the workspace", () => {
    expect(() =>
      saveRunConfigurationEditorChanges(
        "D:/fixture/project",
        "plain-java",
        "project",
        {
          javaHomePath: "C:/Program Files/Java/jdk-21",
          mavenExecutablePath: "",
          mavenJavaHomePath: "",
          workingDirectoryPath: "",
          vmArguments: "",
          programArguments: "",
          environment: {},
        },
        emptyToolchain,
      ),
    ).toThrow("Project paths must stay inside the workspace.");
    expect(executeCore).not.toHaveBeenCalled();
  });
  test("sends toolchain defaults and project options in one core request", async () => {
    await saveRunConfigurationEditorChanges(
      "D:/fixture/project",
      "spring",
      "project",
      {
        javaHomePath: "",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        workingDirectoryPath: "D:/fixture/project/backend",
        vmArguments: "-Xmx2g",
        programArguments: "--dev",
        environment: { APP_ENV: "dev" },
      },
      {
        javaHomePath: "C:/Java/jdk-21",
        mavenExecutablePath: "D:/Tools/apache-maven",
        mavenJavaHomePath: "C:/Java/jdk-17",
        runtimeExecutablePaths: { "project-node": "C:/Program Files/nodejs/node.exe" },
      },
    );

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "runConfig.saveEditorChanges",
        payload: expect.objectContaining({
          root: "D:/fixture/project",
          scope: "project",
          configurationId: "spring",
          workingDirectory: "backend",
          toolchain: {
            javaHomePath: "C:/Java/jdk-21",
            mavenExecutablePath: "D:/Tools/apache-maven",
            mavenJavaHomePath: "C:/Java/jdk-17",
            runtimeExecutablePaths: { "project-node": "C:/Program Files/nodejs/node.exe" },
          },
        }),
      }),
    );
  });
});
