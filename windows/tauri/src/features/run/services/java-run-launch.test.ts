import {
  beginProjectPreparation,
  updateProjectPreparation,
  projectPreparationStore,
} from "../stores/project-preparation.store";
import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import * as javaOwner from "@/features/editor/lsp/java-workspace-language-server";
import * as adapter from "@/platform/lsp-core-adapter";
import type { JavaRunLaunchPreparation } from "./java-run-launch";

const prewarm = mock(async () => ({ kind: "ready" as const }));
const invokeLsp = mock(async (): Promise<JavaRunLaunchPreparation> => ({
  kind: "ready" as const,
  target: {
    mainClass: "com.ruoyi.RuoYiApplication",
    projectName: "ruoyi-admin",
    classPaths: ["D:/work/RuoYi/ruoyi-admin/target/classes"],
    modulePaths: [],
  },
}));

const { prepareJavaRunLaunch } = await import("./java-run-launch");
let restoreMocks: () => void;

function configuration(provider: string): RunConfiguration {
  return {
    id: `${provider}:ruoyi-admin`,
    name: "ruoyi-admin",
    provider,
    kindTitle: "Spring Boot",
    category: "project" as const,
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
  const previousLanguage = useSettingsStore.getState().settings.displayLanguage;
  const owner = spyOn(javaOwner.getJavaWorkspaceLanguageServerOwner(), "prewarm").mockImplementation(prewarm);
  const invoke = spyOn(adapter, "invokeLsp").mockImplementation(invokeLsp as typeof adapter.invokeLsp);
  restoreMocks = () => {
    owner.mockRestore(); invoke.mockRestore();
    useSettingsStore.setState((state) => ({ settings: { ...state.settings, displayLanguage: previousLanguage } }));
  };
  useSettingsStore.setState((state) => ({ settings: { ...state.settings, displayLanguage: "en-US" } }));
  projectPreparationStore.setState({ entries: {} });
  prewarm.mockClear();
  invokeLsp.mockClear();
});
afterEach(() => restoreMocks());

describe("Java project launch preparation", () => {
  test("localizes a continuable build failure while retaining its target and evidence", async () => {
    useSettingsStore.setState((state) => ({ settings: { ...state.settings, displayLanguage: "zh-CN" } }));
    const target = { mainClass: "demo.Main", projectName: "app", classPaths: ["C:/work/classes"], modulePaths: [] };
    const failure = { code: "javaBuildCompilationErrors" as const, message: "The Java project build reported compilation errors." };
    invokeLsp.mockResolvedValueOnce({ kind: "buildFailed", target, failure });
    const result = await prepareJavaRunLaunch(
      { workspaceId: "workspace", root: "D:/work/RuoYi" }, configuration("java.main"));
    expect(result).toEqual({ kind: "buildFailed", target, failure: { ...failure, message: "Java 项目构建报告了编译错误。" } });
  });

  test.each([
    ["en-US", "The Java language service returned no runtime paths."],
    ["zh-CN", "Java 语言服务没有返回运行路径。"],
  ])("localizes shared preparation failures in %s without losing their identity", async (language, expected) => {
    useSettingsStore.setState((state) => ({ settings: { ...state.settings, displayLanguage: language as "en-US" | "zh-CN" } }));
    const failure = Object.assign(new Error("The Java language service returned no runtime paths."), {
      code: "invalidServerResult",
    });
    invokeLsp.mockRejectedValueOnce(failure);
    await expect(prepareJavaRunLaunch(
      { workspaceId: "workspace", root: "D:/work/RuoYi" }, configuration("java.main"),
    )).rejects.toBe(failure);
    expect(failure.message).toBe(expected);
    expect(failure.code).toBe("invalidServerResult");
  });

  test("preserves upstream preparation diagnostics verbatim", async () => {
    useSettingsStore.setState((state) => ({ settings: { ...state.settings, displayLanguage: "zh-CN" } }));
    const failure = new Error("Upstream fixture detail: example.Main");
    invokeLsp.mockRejectedValueOnce(failure);
    await expect(prepareJavaRunLaunch(
      { workspaceId: "workspace", root: "D:/work/RuoYi" }, configuration("java.main"),
    )).rejects.toBe(failure);
    expect(failure.message).toBe("Upstream fixture detail: example.Main");
  });

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
    expect(target?.target.mainClass).toBe("com.ruoyi.RuoYiApplication");
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

test("Core owns the bounded wait when project configuration is still syncing", async () => {
  beginProjectPreparation("D:/work/RuoYi", "java");
  updateProjectPreparation("D:/work/RuoYi", "java", {
    phase: "configuring",
    status: "loading",
    blocksRun: true,
  });
  await prepareJavaRunLaunch(
    { workspaceId: "workspace", root: "D:/work/RuoYi" },
    configuration("spring-boot.maven"),
  );
  expect(invokeLsp).toHaveBeenCalledTimes(1);
});
