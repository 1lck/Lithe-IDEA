import { expect, mock, test } from "bun:test";
import { IdeCapabilities } from "./ide-capabilities";
import { createRunStore } from "@/features/run/stores/run.store";
import { createMavenStore } from "@/features/maven/stores/maven.store";
import { EMPTY_GLOBAL_TOOLCHAIN, PRIMARY_SESSION_ID } from "@/features/run/types/run.types";
import type { MavenWorkspaceReloadOutcome } from "@/features/maven/services/reload-maven-workspace";

function fixture() {
  const root = "C:/fixture/project";
  const run = createRunStore("api-fixture", { stopRunProcess: async () => {} });
  const maven = createMavenStore("api-fixture");
  run.setState({ root, status: "ready" });
  maven.setState({ root });
  const dependencies = {
    outputPage: async (snapshot: unknown) => snapshot,
    validate: mock(async (name: string) => ({
      ok: true,
      mutation: name.endsWith("_configure") || name.endsWith("_reload"),
    })),
    hasWorkspace: () => true,
    workspaceName: () => "fixture",
    workspaceRoot: () => root,
    mavenStore: () => maven,
    runStore: () => run,
    loadProjectEnvironment: mock(async () => ({
      toolchain: { ...EMPTY_GLOBAL_TOOLCHAIN, javaHomePath: "C:/fixture/jdk-21" },
      discovered: { java: [], maven: [], runtimes: [] },
      discoveryError: null,
    })),
    saveProjectEnvironmentSettings: mock(
      async (
        ..._args: Parameters<
          typeof import("@/features/settings/services/project-environment").saveProjectEnvironmentSettings
        >
      ) => ({ runRefresh: Promise.resolve(null) }),
    ),
    resolveRunToolchains: mock(async () => ({
      java: { status: "notFound" as const, message: null },
      maven: { status: "notFound" as const, message: null },
      mavenJava: { status: "notFound" as const, message: null },
    })),
    mavenLaunchContextForWorkspace: mock(async () => null),
    reloadMavenWorkspaceProjects: mock(
      async (): Promise<MavenWorkspaceReloadOutcome> => "completed",
    ),
  };
  const api = new IdeCapabilities(
    "api-fixture",
    root,
    { configure: true, execute: true },
    dependencies,
  );
  return { api, run, maven, dependencies };
}

test("API output follows an execution identity, and an old stop cannot target its replacement", async () => {
  const { api, run } = fixture();
  const stop = mock(async () => {});
  run.setState({
    sessions: [
      {
        id: "slot",
        configurationId: "service",
        executionId: "first",
        title: "service",
        output: "first output",
        isRunning: true,
        exitCode: null,
      },
    ],
    actions: { ...run.getState().actions, stop },
  });
  expect(await api.call("lithe_operation_output", { operationID: "run:first" })).toMatchObject({
    output: "first output",
  });
  run.setState({
    sessions: [{ ...run.getState().sessions[0], executionId: "second", output: "second output" }],
  });
  expect(await api.call("lithe_operation_stop", { operationID: "run:first" })).toMatchObject({
    error: { code: "OPERATION_EXPIRED" },
  });
  expect(stop).not.toHaveBeenCalled();
  await api.call("lithe_operation_stop", { operationID: "run:second" });
  expect(stop).toHaveBeenCalledWith("slot", "second");
});

test("revoking access while environment discovery resolves prevents configuration writes", async () => {
  const { api, dependencies } = fixture();
  const original = dependencies.loadProjectEnvironment;
  dependencies.loadProjectEnvironment = mock(async () => {
    const result = await original();
    api.revoke();
    return result;
  });
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "OPERATION_FAILED" },
  });
  expect(dependencies.saveProjectEnvironmentSettings).not.toHaveBeenCalled();
});

test("application output in the primary panel uses the same execution identity protection", async () => {
  const { api, run } = fixture();
  const stop = mock(async () => {});
  run.setState({
    primaryExecutionId: "app-first",
    primaryConfigurationId: "application",
    primaryOutput: "application output",
    primaryExitCode: 1,
    actions: { ...run.getState().actions, stop },
  });
  expect(await api.call("lithe_operation_output", { operationID: "run:app-first" })).toMatchObject({
    output: "application output",
    state: "failed",
    exitCode: 1,
  });
  run.setState({ primaryExecutionId: "app-second" });
  expect(await api.call("lithe_operation_stop", { operationID: "run:app-first" })).toMatchObject({
    error: { code: "OPERATION_EXPIRED" },
  });
  expect(stop).not.toHaveBeenCalled();
  await api.call("lithe_operation_stop", { operationID: "run:app-second" });
  expect(stop).toHaveBeenCalledWith(PRIMARY_SESSION_ID, "app-second");
});

test("environment patch preserves omitted defaults and rejects Maven-only paths without Maven", async () => {
  const { api, dependencies } = fixture();
  await api.call("lithe_environment_configure", { mavenJavaHomePath: "C:/fixture/build-jdk" });
  expect(dependencies.saveProjectEnvironmentSettings.mock.calls[0]?.[1]).toMatchObject({
    javaHomePath: "C:/fixture/jdk-21",
    mavenJavaHomePath: "C:/fixture/build-jdk",
  });
  expect(
    await api.call("lithe_environment_configure", { settingsPath: "C:/fixture/settings.xml" }),
  ).toMatchObject({ error: { code: "NOT_READY" } });
  expect(dependencies.saveProjectEnvironmentSettings).toHaveBeenCalledTimes(1);
});

test("shared authorization failures stop before application actions", async () => {
  const { api, dependencies } = fixture();
  dependencies.validate = mock(async () => ({
    ok: false,
    mutation: false,
    error: { code: "PERMISSION_DENIED" },
  }));
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "PERMISSION_DENIED" },
  });
  expect(dependencies.loadProjectEnvironment).not.toHaveBeenCalled();
});

test("a failed Maven reload is reported as a tool error", async () => {
  const { api, dependencies } = fixture();
  dependencies.reloadMavenWorkspaceProjects = mock(async () => "failed" as const);
  expect(await api.call("lithe_maven_reload", {})).toMatchObject({
    error: { code: "OPERATION_FAILED" },
  });
});

test("overlapping mutations are busy while inspections can continue, and failed saves release the slot", async () => {
  const { api, dependencies } = fixture();
  const original = dependencies.loadProjectEnvironment;
  dependencies.loadProjectEnvironment = mock(async () => {
    expect(await api.call("lithe_maven_reload", {})).toMatchObject({ error: { code: "BUSY" } });
    expect(await api.call("lithe_project_inspect", {})).toMatchObject({ name: "fixture" });
    return original();
  });
  dependencies.saveProjectEnvironmentSettings = mock(async () => {
    throw new Error("Fixture save failed");
  });
  expect(await api.call("lithe_environment_configure", { javaHomePath: "" })).toMatchObject({
    error: { code: "OPERATION_FAILED", message: "Fixture save failed" },
  });
  expect(dependencies.reloadMavenWorkspaceProjects).not.toHaveBeenCalled();
  expect(await api.call("lithe_maven_reload", {})).toMatchObject({ outcome: "completed" });
});

test("Maven profile configuration adds only undeclared profiles as custom entries", async () => {
  const { api, maven } = fixture();
  const actions = maven.getState().actions;
  const addCustomProfile = mock((_profile: string) => true);
  const setSelectedProfiles = mock((_profiles: string[]) => {});
  const saveLocalConfiguration = mock(async () => {});
  maven.setState({
    project: {
      relativePath: ".",
      artifactId: "fixture",
      packaging: "pom",
      sourceRoots: [],
      modules: [],
      profiles: [{ id: "dev", isActiveByDefault: false }],
      hasWrapper: false,
    },
    actions: { ...actions, addCustomProfile, setSelectedProfiles, saveLocalConfiguration },
  });
  expect(await api.call("lithe_maven_configure", { profiles: ["dev", "ci"] })).toMatchObject({
    saved: true,
  });
  expect(addCustomProfile.mock.calls).toEqual([["ci"]]);
  expect(setSelectedProfiles).toHaveBeenCalledWith(["dev", "ci"]);
  expect(saveLocalConfiguration).toHaveBeenCalledTimes(1);
});
