import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";

const prewarm = mock(async () => ({ kind: "ready" as const }));
const invokeLsp = mock(async () => ({
  mainClass: "com.ruoyi.RuoYiApplication",
  projectName: "ruoyi-admin",
  classPaths: ["D:/work/RuoYi/ruoyi-admin/target/classes"],
  modulePaths: [],
}));

mock.module("@/features/editor/lsp/java-workspace-language-server", () => ({
  getJavaWorkspaceLanguageServerOwner: () => ({ prewarm }),
}));
mock.module("@/platform/lsp-core-adapter", () => ({ invokeLsp }));

const { prepareJavaRunLaunch } = await import("./java-run-launch");

function configuration(provider: string): RunConfiguration {
  return {
    id: `${provider}:ruoyi-admin`,
    name: "ruoyi-admin",
    provider,
    kindTitle: "Spring Boot",
    execution: "service",
    toolchains: { java: "project-jdk", maven: "project-maven" },
    mavenReactorPath: ".",
    mainClass: "com.ruoyi.RuoYiApplication",
    sourcePath: "ruoyi-admin/src/main/java/com/ruoyi/RuoYiApplication.java",
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
    source: "generated",
    disabled: false,
  };
}

beforeEach(() => {
  prewarm.mockClear();
  invokeLsp.mockClear();
});

describe("Java project launch preparation", () => {
  test("prepares a detected Spring Boot service through JDT", async () => {
    const target = await prepareJavaRunLaunch(
      { workspaceId: "workspace", root: "D:/work/RuoYi" },
      configuration("spring-boot.maven"),
    );

    expect(prewarm).toHaveBeenCalledWith(
      { workspaceId: "workspace", root: "D:/work/RuoYi" },
      "D:/work/RuoYi/ruoyi-admin/src/main/java/com/ruoyi/RuoYiApplication.java",
    );
    expect(invokeLsp).toHaveBeenCalledWith("java_prepare_run_launch", {
      workspacePath: "D:/work/RuoYi",
      sourcePath: "D:/work/RuoYi/ruoyi-admin/src/main/java/com/ruoyi/RuoYiApplication.java",
      mainClass: "com.ruoyi.RuoYiApplication",
    });
    expect(target?.mainClass).toBe("com.ruoyi.RuoYiApplication");
  });

  test("leaves non-Java framework services on their own launcher", async () => {
    expect(
      await prepareJavaRunLaunch(
        { workspaceId: "workspace", root: "D:/work/RuoYi" },
        configuration("quarkus.maven"),
      ),
    ).toBeNull();
    expect(prewarm).not.toHaveBeenCalled();
    expect(invokeLsp).not.toHaveBeenCalled();
  });
});
