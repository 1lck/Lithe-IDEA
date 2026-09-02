import { beforeEach, describe, expect, mock, test } from "bun:test";

const executeCore = mock(async () => ({
  id: "request",
  ok: true as const,
  data: { document: "{}" },
}));
const cancelCoreOperation = mock(async () => true);

mock.module("@/core/lithe-core-client", () => ({ executeCore, cancelCoreOperation }));

const { createLaunchPlan, saveRunConfigurationEditorChanges } = await import("./run-core-api");

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
  test("forwards the shared Maven context when creating a launch plan", async () => {
    const mavenContext = {
      version: 1 as const,
      reactorPath: "reactor",
      profiles: ["dev"],
      settingsPath: "C:/Users/example/.m2/settings.xml",
      skipTests: true,
      mavenExecutablePath: "D:/Tools/apache-maven",
      javaHomePath: "C:/Java/jdk-21",
    };

    await createLaunchPlan("D:/fixture/project", "spring", undefined, mavenContext);

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        command: "runConfig.createLaunchPlan",
        payload: {
          root: "D:/fixture/project",
          configurationId: "spring",
          currentFile: undefined,
          mavenContext,
        },
      }),
    );
  });

  test("sends project-relative working directory and toolchain paths in project scope", async () => {
    await saveRunConfigurationEditorChanges(
      "D:/fixture/project",
      "plain-java",
      "project",
      {
        javaHomePath: "D:\\fixture\\project\\toolchains\\jdk",
        mavenExecutablePath: "D:/fixture/project/toolchains/maven/bin/mvn.cmd",
        mavenJavaHomePath: "D:/fixture/project/toolchains/maven-jdk",
        mavenSkipTests: false,
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
          mavenSkipTests: false,
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

  test("uses empty working directory and null test override to inherit project defaults", async () => {
    await saveRunConfigurationEditorChanges(
      "D:/fixture/project",
      "spring",
      "project",
      {
        javaHomePath: "",
        mavenExecutablePath: "",
        mavenJavaHomePath: "",
        mavenSkipTests: null,
        workingDirectoryPath: "",
        vmArguments: "",
        programArguments: "",
        environment: {},
      },
      emptyToolchain,
    );

    expect(executeCore).toHaveBeenCalledWith(
      expect.objectContaining({
        payload: expect.objectContaining({
          workingDirectory: "",
          mavenSkipTests: null,
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
