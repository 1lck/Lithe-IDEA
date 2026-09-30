import { invoke } from "@/platform/tauri-core";
import { useMavenStore, mavenLaunchContextForWorkspace } from "@/features/maven/stores/maven.store";
import { reloadMavenWorkspaceProjects } from "@/features/maven/services/reload-maven-workspace";
import { useRunStore } from "@/features/run/stores/run.store";
import { resolveRunToolchains } from "@/features/run/api/run-host-api";
import {
  loadProjectEnvironment,
  saveProjectEnvironmentSettings,
} from "@/features/settings/services/project-environment";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { MavenModule } from "@/features/maven/types/maven.types";
import { PRIMARY_SESSION_ID } from "@/features/run/types/run.types";

export interface IdePermissions {
  configure: boolean;
  execute: boolean;
}
export interface IdeRequest {
  requestID: string;
  name: string;
  arguments: Record<string, unknown>;
}
export const hostControl = <T>(action: string, args: Record<string, unknown> = {}) =>
  invoke<T>("ideHost.control", { action, arguments: args });

function fail(code: string, message: string) {
  return { ok: false, error: { code, message } };
}

const defaultDependencies = {
  outputPage: (snapshot: unknown, cursor: unknown) => hostControl("output", { snapshot, cursor }),
  validate: (name: string, args: Record<string, unknown>, permissions: IdePermissions) =>
    hostControl<{ ok: boolean; mutation?: boolean; error?: unknown }>("validate", {
      name,
      arguments: args,
      permissions,
    }),
  hasWorkspace: (id: string) => workspaceRuntimeRegistry.hasWorkspace(id),
  workspaceName: (id: string) => workspaceRuntimeRegistry.getWorkspace(id)?.descriptor.name,
  workspaceRoot: (id: string) => useFileSystemStore.getStore(id).getState().rootFolderPath,
  mavenStore: (id: string) => useMavenStore.getStore(id),
  runStore: (id: string) => useRunStore.getStore(id),
  loadProjectEnvironment,
  saveProjectEnvironmentSettings,
  resolveRunToolchains,
  mavenLaunchContextForWorkspace,
  reloadMavenWorkspaceProjects,
};

/** A workspace-bound application API; never consults the currently focused tab. */
export class IdeCapabilities {
  private active = true;
  private mutationInFlight = false;
  revoke() {
    this.active = false;
  }
  constructor(
    readonly workspaceId: string,
    readonly root: string,
    readonly permissions: IdePermissions,
    private readonly dependencies = defaultDependencies,
  ) {}
  isCurrent() {
    return (
      this.active &&
      this.dependencies.hasWorkspace(this.workspaceId) &&
      this.dependencies.workspaceRoot(this.workspaceId) === this.root
    );
  }
  private get maven() {
    return this.dependencies.mavenStore(this.workspaceId).getState();
  }
  private get run() {
    return this.dependencies.runStore(this.workspaceId).getState();
  }
  private operations() {
    const m = this.maven;
    const result = this.run.sessions
      .filter((s) => s.executionId)
      .map((s) => ({
        operationID: `run:${s.executionId}`,
        kind: "run",
        configurationID: s.configurationId,
        sessionID: s.id,
        title: s.title,
        state: s.isRunning
          ? "running"
          : s.isPreparing
            ? "preparing"
            : s.exitCode === null
              ? "cancelled"
              : s.exitCode === 0
                ? "completed"
                : "failed",
        exitCode: s.exitCode,
        output: s.output,
      }));
    const primary = this.run;
    if (primary.primaryExecutionId)
      result.push({
        operationID: `run:${primary.primaryExecutionId}`,
        kind: "run",
        configurationID: primary.primaryConfigurationId ?? "",
        sessionID: PRIMARY_SESSION_ID,
        title: primary.primaryTitle ?? "Run",
        state: primary.primaryRunning
          ? "running"
          : primary.primaryPreparing
            ? "preparing"
            : primary.primaryExitCode === null
              ? "cancelled"
              : primary.primaryExitCode === 0
                ? "completed"
                : "failed",
        exitCode: primary.primaryExitCode,
        output: primary.primaryOutput,
      });
    if (m.outputOperationID)
      result.push({
        operationID: m.outputOperationID,
        kind: "maven",
        configurationID: "",
        sessionID: m.outputOperationID,
        title: m.taskTitle ?? "Maven",
        state:
          m.taskStatus === "running" || m.taskStatus === "stopping"
            ? m.taskStatus
            : m.lastExitCode === 0
              ? "completed"
              : m.taskStatus === "cancelled"
                ? "cancelled"
                : "failed",
        exitCode: m.lastExitCode,
        output: m.output,
      });
    return result.sort((a, b) => a.operationID.localeCompare(b.operationID));
  }
  async call(name: string, args: Record<string, unknown>): Promise<unknown> {
    let ownsMutation = false;
    try {
      if (!this.isCurrent())
        return fail("WORKSPACE_CLOSED", "The authorized project was closed or replaced");
      const validation = await this.dependencies.validate(name, args, this.permissions);
      if (!validation.ok) return validation;
      if (!this.isCurrent()) return fail("WORKSPACE_CLOSED", "The authorized project was closed");
      if (validation.mutation && this.mutationInFlight)
        return fail("BUSY", "Another configuration or launch request is in progress");
      if (validation.mutation) {
        this.mutationInFlight = true;
        ownsMutation = true;
      }
      const result = await this.execute(name, args);
      if (
        name === "lithe_operation_output" &&
        result &&
        typeof result === "object" &&
        !("error" in result)
      )
        return await this.dependencies.outputPage(result, args.cursor);
      return result;
    } catch (error) {
      return fail("OPERATION_FAILED", error instanceof Error ? error.message : String(error));
    } finally {
      if (ownsMutation) this.mutationInFlight = false;
    }
  }
  private async execute(name: string, args: Record<string, unknown>): Promise<unknown> {
    const assertCurrent = () => {
      if (!this.isCurrent()) throw new Error("The authorized project was closed");
    };
    switch (name) {
      case "lithe_project_inspect":
        return {
          workspaceID: this.workspaceId,
          name: this.dependencies.workspaceName(this.workspaceId),
          permissions: this.permissions,
          runStatus: this.run.status,
          mavenStatus: this.maven.projectStatus,
        };
      case "lithe_environment_inspect": {
        const environment = await this.dependencies.loadProjectEnvironment(this.root);
        assertCurrent();
        await this.dependencies.mavenLaunchContextForWorkspace(this.root, [], this.workspaceId);
        assertCurrent();
        const selection = {
          ...environment.toolchain,
          mavenExecutablePath:
            this.maven.mavenExecutablePath || environment.toolchain.mavenExecutablePath,
          mavenJavaHomePath: this.maven.javaHomePath || environment.toolchain.mavenJavaHomePath,
        };
        const effective = await this.dependencies.resolveRunToolchains(this.root, selection);
        assertCurrent();
        return {
          scope: "project-local",
          settings: {
            ...selection,
            settingsPath: this.maven.settingsPath,
            localRepositoryPath: this.maven.localRepositoryPath,
          },
          discovered: environment.discovered,
          discoveryError: environment.discoveryError,
          effective,
        };
      }
      case "lithe_environment_configure": {
        const environment = await this.dependencies.loadProjectEnvironment(this.root);
        assertCurrent();
        await this.dependencies.mavenLaunchContextForWorkspace(this.root, [], this.workspaceId);
        assertCurrent();
        const m = this.maven;
        if (
          !m.project &&
          (args.settingsPath !== undefined || args.localRepositoryPath !== undefined)
        )
          return fail("NOT_READY", "No Maven project is loaded");
        const selection = {
          ...environment.toolchain,
          javaHomePath:
            (args.javaHomePath as string | undefined) ?? environment.toolchain.javaHomePath,
          mavenExecutablePath:
            (args.mavenExecutablePath as string | undefined) ??
            (m.mavenExecutablePath || environment.toolchain.mavenExecutablePath),
          mavenJavaHomePath:
            (args.mavenJavaHomePath as string | undefined) ??
            (m.javaHomePath || environment.toolchain.mavenJavaHomePath),
        };
        const saved = await this.dependencies.saveProjectEnvironmentSettings(this.root, selection, {
          maven: m.project
            ? {
                store: this.dependencies.mavenStore(this.workspaceId),
                settings: {
                  settingsPath: (args.settingsPath as string | undefined) ?? m.settingsPath,
                  localRepositoryPath:
                    (args.localRepositoryPath as string | undefined) ?? m.localRepositoryPath,
                  mavenExecutablePath: selection.mavenExecutablePath,
                  javaHomePath: selection.mavenJavaHomePath,
                },
              }
            : null,
          run: this.dependencies.runStore(this.workspaceId),
        });
        const refreshError = await saved.runRefresh;
        assertCurrent();
        return {
          saved: true,
          scope: "project-local",
          refreshError,
          effective: await this.dependencies.resolveRunToolchains(this.root, selection),
        };
      }
      case "lithe_maven_inspect": {
        await this.dependencies.mavenLaunchContextForWorkspace(this.root, [], this.workspaceId);
        assertCurrent();
        const m = this.maven;
        return {
          project: m.project,
          profiles: m.selectedProfiles,
          skipTests: m.skipTests,
          reloadRequired: m.reloadRequired,
          diagnostic: m.projectError ?? m.configurationSaveError ?? m.javaConfigurationError,
        };
      }
      case "lithe_maven_configure": {
        if (!this.maven.project) return fail("NOT_READY", "Load a Maven project first");
        if (args.profiles) {
          const profiles = args.profiles as string[];
          // Only undeclared profiles become custom entries; POM profiles stay owned by the model.
          const declared = new Set(this.maven.project.profiles.map((profile) => profile.id));
          for (const profile of profiles)
            if (!declared.has(profile)) this.maven.actions.addCustomProfile(profile);
          this.maven.actions.setSelectedProfiles(profiles);
        }
        if (typeof args.skipTests === "boolean") this.maven.actions.setSkipTests(args.skipTests);
        const m = this.maven;
        await m.actions.saveLocalConfiguration({
          settingsPath: m.settingsPath,
          localRepositoryPath: m.localRepositoryPath,
          mavenExecutablePath: m.mavenExecutablePath,
          javaHomePath: m.javaHomePath,
        });
        assertCurrent();
        return {
          saved: true,
          profiles: this.maven.selectedProfiles,
          skipTests: this.maven.skipTests,
          reloadRequired: this.maven.reloadRequired,
        };
      }
      case "lithe_maven_reload": {
        const outcome = await this.dependencies.reloadMavenWorkspaceProjects({
          workspaceId: this.workspaceId,
          root: this.root,
        });
        assertCurrent();
        if (outcome === "failed")
          return fail("OPERATION_FAILED", this.maven.projectError ?? "Maven project reload failed");
        if (outcome === "stale")
          return fail("NOT_READY", "The Maven project changed during reload");
        return { outcome };
      }
      case "lithe_maven_execute": {
        if (!this.maven.project) return fail("NOT_READY", "Load a Maven project first");
        if (["running", "stopping"].includes(this.maven.taskStatus))
          return fail("BUSY", "A Maven execution is already active");
        const modulePath = (args.modulePath as string | undefined) ?? null;
        const contains = (modules: MavenModule[]): boolean =>
          modules.some((m) => m.relativePath === modulePath || contains(m.modules));
        if (modulePath && modulePath !== "." && !contains(this.maven.project.modules))
          return fail("NOT_FOUND", "Unknown Maven module");
        const goals = args.goals as string[];
        await this.maven.actions.runGoals(
          goals,
          modulePath === "." ? null : modulePath,
          goals.join(" "),
        );
        assertCurrent();
        return {
          ...(this.maven.taskError ? fail("LAUNCH_FAILED", this.maven.taskError) : {}),
          operationID: this.maven.outputOperationID,
          state: this.maven.taskStatus,
        };
      }
      case "lithe_run_list": {
        if (this.run.root !== this.root) await this.run.actions.loadProject(this.root);
        assertCurrent();
        return {
          status: this.run.status,
          diagnostic: this.run.invalidMessage,
          configurations: this.run.configurations
            .filter((c) => c.id !== "current-file")
            .map((c) => ({ id: c.id, name: c.name, provider: c.provider, disabled: c.disabled })),
          diagnostics: this.run.diagnostics,
        };
      }
      case "lithe_run_start":
        return this.start(args.configurationID as string);
      case "lithe_operations_list":
        return {
          operations: this.operations().map(({ output, sessionID, ...summary }) => summary),
        };
      case "lithe_operation_output":
      case "lithe_operation_stop":
      case "lithe_run_restart": {
        const operation = this.operations().find((o) => o.operationID === args.operationID);
        if (!operation)
          return fail(
            "OPERATION_EXPIRED",
            "This execution has exited the IDE history or was replaced",
          );
        if (name === "lithe_operation_output") return operation;
        if (name === "lithe_run_restart" && operation.configurationID === "current-file")
          return fail("INVALID_ARGUMENTS", "Restart requires a saved project configuration");
        if (operation.kind === "maven") {
          if (name === "lithe_run_restart")
            return fail("INVALID_ARGUMENTS", "Use Maven execute to start another build");
          if (this.maven.activeSessionId === operation.operationID) await this.maven.actions.stop();
        } else {
          await this.run.actions.stop(operation.sessionID, operation.operationID.slice(4));
          assertCurrent();
          if (name === "lithe_run_restart") return this.start(operation.configurationID);
        }
        return { operationID: operation.operationID, stopRequested: true };
      }
      default:
        return fail("NOT_SUPPORTED", "Unknown IDE capability");
    }
  }
  private async start(id: string) {
    const configuration = this.run.configurations.find((c) => c.id === id);
    if (!configuration || id === "current-file")
      return fail("NOT_FOUND", "Choose an existing project run configuration");
    if (
      this.operations().some(
        (operation) =>
          operation.configurationID === id && ["running", "preparing"].includes(operation.state),
      ) ||
      (configuration.execution !== "service" &&
        (this.run.primaryRunning || this.run.primaryPreparing))
    )
      return fail(
        "BUSY",
        "This configuration is already running; use restart with its operationID",
      );
    const previous = this.operations().find(
      (operation) => operation.configurationID === id,
    )?.operationID;
    const instance = await this.run.actions.runConfigurationInstance(id);
    if (!this.isCurrent()) return fail("WORKSPACE_CLOSED", "The authorized project was closed");
    if (!instance) {
      const failed = this.operations().find(
        (operation) => operation.configurationID === id && operation.operationID !== previous,
      );
      return {
        ...fail(
          "LAUNCH_FAILED",
          "Launch did not start. Check IDE run output and any pending launch decision.",
        ),
        operationID: failed?.operationID ?? null,
      };
    }
    return { operationID: `run:${instance.executionId}` };
  }
}
