import { createStore } from "zustand/vanilla";
import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  createMavenDependencyPlan,
  createMavenLaunchPlan,
  parseMavenDependencies,
  parseMavenDiagnostics,
  scanMavenProject,
} from "../api/maven-core-api";
import {
  loadMavenConfiguration,
  resolveMavenLaunch,
  startMavenProcess,
  stopMavenProcess,
  writeMavenConfiguration,
} from "../api/maven-host-api";
import type {
  MavenDependencyLoad,
  MavenDiagnostic,
  MavenLaunchContext,
  MavenLocalConfiguration,
  MavenPortableConfiguration,
  MavenProfile,
  MavenProject,
  MavenProjectStatus,
  MavenSettings,
  MavenStoredConfiguration,
  MavenTaskStatus,
} from "../types/maven.types";

const MAXIMUM_OUTPUT_CHARACTERS = 500_000;
const MAXIMUM_DEPENDENCY_OUTPUT_CHARACTERS = 500_000;
const MAVEN_DEPENDENCY_TIMEOUT_MILLISECONDS = 60_000;
const mavenSessionWorkspaces = new Map<string, string>();

interface MavenProjectLoad {
  task: Promise<void>;
  hasVisiblePaths: boolean;
}

const mavenProjectLoads = new Map<string, MavenProjectLoad>();

export interface MavenStoreDependencies {
  createMavenDependencyPlan: typeof createMavenDependencyPlan;
  createMavenLaunchPlan: typeof createMavenLaunchPlan;
  loadMavenConfiguration: typeof loadMavenConfiguration;
  parseMavenDiagnostics: typeof parseMavenDiagnostics;
  parseMavenDependencies: typeof parseMavenDependencies;
  resolveMavenLaunch: typeof resolveMavenLaunch;
  saveWorkspaceBeforeLaunch: typeof saveWorkspaceBeforeLaunch;
  scanMavenProject: typeof scanMavenProject;
  startMavenProcess: typeof startMavenProcess;
  stopMavenProcess: typeof stopMavenProcess;
  writeMavenConfiguration: typeof writeMavenConfiguration;
}

const defaultMavenStoreDependencies: MavenStoreDependencies = {
  createMavenDependencyPlan,
  createMavenLaunchPlan,
  loadMavenConfiguration,
  parseMavenDiagnostics,
  parseMavenDependencies,
  resolveMavenLaunch,
  saveWorkspaceBeforeLaunch,
  scanMavenProject,
  startMavenProcess,
  stopMavenProcess,
  writeMavenConfiguration,
};

export interface MavenDependencyScheduler {
  setTimer: (
    callback: () => void | Promise<void>,
    milliseconds: number,
  ) => ReturnType<typeof setTimeout>;
  clearTimer: (timer: ReturnType<typeof setTimeout>) => void;
}

const defaultMavenDependencyScheduler: MavenDependencyScheduler = {
  setTimer: (callback, milliseconds) => setTimeout(() => void callback(), milliseconds),
  clearTimer: (timer) => clearTimeout(timer),
};

export interface MavenState {
  root: string | null;
  visiblePaths: string[];
  projectStatus: MavenProjectStatus;
  projectError: string | null;
  project: MavenProject | null;
  selectedProfiles: string[];
  customProfiles: string[];
  skipTests: boolean;
  settingsPath: string;
  localRepositoryPath: string;
  mavenExecutablePath: string;
  javaHomePath: string;
  configurationSaveError: string | null;
  reloadRequired: boolean;
  taskStatus: MavenTaskStatus;
  taskError: string | null;
  activeSessionId: string | null;
  runningTitle: string | null;
  output: string;
  issues: MavenDiagnostic[];
  lastExitCode: number | null;
  dependencyLoads: Record<string, MavenDependencyLoad>;
  activeDependencySessionId: string | null;
  activeDependencyModulePath: string | null;
  dependencyOutput: string;
  actions: {
    loadProject: (root: string, visiblePaths?: string[]) => Promise<void>;
    setSelectedProfiles: (profiles: string[]) => void;
    addCustomProfile: (profile: string) => boolean;
    restoreDefaultProfiles: () => void;
    setSkipTests: (enabled: boolean) => void;
    updateLocalConfiguration: (settings: MavenSettings) => void;
    acknowledgeReload: () => void;
    runGoals: (goals: string[], module: string | null, title: string) => Promise<void>;
    stop: () => Promise<void>;
    clearOutput: () => void;
    appendOutput: (sessionId: string, chunk: string) => void;
    finishProcess: (sessionId: string, exitCode: number) => void;
    loadDependencies: (modulePath: string) => Promise<void>;
    cancelDependencies: (modulePath: string) => Promise<void>;
    appendDependencyOutput: (sessionId: string, chunk: string) => void;
    finishDependencyProcess: (sessionId: string, exitCode: number) => Promise<void>;
  };
}

function normalizedProfile(value: string): string | null {
  const profile = value.trim();
  const hasControlCharacter = [...profile].some((character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || code === 0x7f;
  });
  if (!profile || profile.includes(",") || hasControlCharacter) return null;
  return profile;
}

function normalizedProfiles(values: readonly string[]): string[] {
  return [
    ...new Set(values.map(normalizedProfile).filter((value): value is string => !!value)),
  ].sort();
}

function normalizedPath(value: string | null | undefined): string {
  return value?.trim() ?? "";
}

export function availableMavenProfiles(state: Pick<MavenState, "project" | "customProfiles">) {
  const profiles = new Map<string, MavenProfile>();
  for (const profile of state.project?.profiles ?? []) profiles.set(profile.id, profile);
  for (const id of state.customProfiles) {
    if (!profiles.has(id)) profiles.set(id, { id, isActiveByDefault: false });
  }
  return [...profiles.values()];
}

export function mavenLaunchContext(state: MavenState): MavenLaunchContext | null {
  if (!state.project) return null;
  return {
    version: 1,
    reactorPath: state.project.relativePath,
    profiles: normalizedProfiles(state.selectedProfiles),
    settingsPath: state.settingsPath || null,
    localRepositoryPath: state.localRepositoryPath || null,
    skipTests: state.skipTests,
    mavenExecutablePath: state.mavenExecutablePath || null,
    javaHomePath: state.javaHomePath || null,
  };
}

function storedConfiguration(state: MavenState): MavenStoredConfiguration {
  const portable: MavenPortableConfiguration = {
    version: 1,
    selectedProfiles: normalizedProfiles(state.selectedProfiles),
    customProfiles: normalizedProfiles(state.customProfiles),
    skipTests: state.skipTests,
  };
  const local: MavenLocalConfiguration = {
    version: 1,
    settingsPath: state.settingsPath || null,
    localRepositoryPath: state.localRepositoryPath || null,
    mavenExecutablePath: state.mavenExecutablePath || null,
    javaHomePath: state.javaHomePath || null,
  };
  return { portable, local };
}

function displayArguments(arguments_: readonly string[]): string {
  return arguments_
    .map((argument, index) => {
      if (index > 0 && arguments_[index - 1] === "-s") return "<settings.xml>";
      if (argument.startsWith("-Dmaven.repo.local=")) return "-Dmaven.repo.local=<localRepository>";
      return argument;
    })
    .join(" ");
}

function trimOutput(output: string): string {
  const normalized = output.replace(/\r/g, "");
  return normalized.length > MAXIMUM_OUTPUT_CHARACTERS
    ? normalized.slice(normalized.length - MAXIMUM_OUTPUT_CHARACTERS)
    : normalized;
}

function cancelledOutput(output: string): string {
  const separator = output && !output.endsWith("\n") ? "\n" : "";
  return trimOutput(`${output}${separator}Maven task cancelled.\n`);
}

export const createMavenStore = (
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
  dependencies: MavenStoreDependencies = defaultMavenStoreDependencies,
  dependencyScheduler: MavenDependencyScheduler = defaultMavenDependencyScheduler,
) => {
  let projectLoadRevision = 0;
  let configurationRevision = 0;
  let launchRevision = 0;
  let diagnosticsRevision = 0;
  let dependencyRevision = 0;
  let dependencyTimer: ReturnType<typeof setTimeout> | null = null;
  let configurationWriteTask = Promise.resolve();

  return createStore<MavenState>()((set, get) => {
    const clearDependencyTimer = () => {
      if (dependencyTimer === null) return;
      dependencyScheduler.clearTimer(dependencyTimer);
      dependencyTimer = null;
    };

    const setDependencyLoad = (modulePath: string, load: MavenDependencyLoad) => {
      set((state) => ({
        dependencyLoads: { ...state.dependencyLoads, [modulePath]: load },
      }));
    };

    const invalidateDependencies = () => {
      dependencyRevision += 1;
      clearDependencyTimer();
      const sessionId = get().activeDependencySessionId;
      set({
        dependencyLoads: {},
        activeDependencySessionId: null,
        activeDependencyModulePath: null,
        dependencyOutput: "",
      });
      if (!sessionId) return;
      void dependencies
        .stopMavenProcess(sessionId)
        .catch(() => {
          // Invalidation owns stale-result rejection even if the native process
          // has already exited before the stop request reaches it.
        })
        .finally(() => releaseMavenSessionWorkspace(sessionId));
    };

    const failDependencySession = async (
      sessionId: string,
      modulePath: string,
      message: string,
    ) => {
      if (
        get().activeDependencySessionId !== sessionId ||
        get().activeDependencyModulePath !== modulePath
      ) {
        return;
      }
      dependencyRevision += 1;
      clearDependencyTimer();
      set({
        activeDependencySessionId: null,
        activeDependencyModulePath: null,
        dependencyOutput: "",
      });
      setDependencyLoad(modulePath, { status: "failed", dependencies: [], error: message });
      try {
        await dependencies.stopMavenProcess(sessionId);
      } catch {
        // The failure state remains actionable when the process exited while
        // the stop request was in flight.
      } finally {
        releaseMavenSessionWorkspace(sessionId);
      }
    };

    const persistConfiguration = () => {
      const state = get();
      if (!state.root || !state.project) return;
      const revision = ++configurationRevision;
      const configuration = storedConfiguration(state);
      const root = state.root;
      const reactorPath = state.project.relativePath;
      configurationWriteTask = configurationWriteTask
        .catch(() => undefined)
        .then(() => dependencies.writeMavenConfiguration(root, reactorPath, configuration));
      void configurationWriteTask
        .then(() => {
          if (configurationRevision === revision) set({ configurationSaveError: null });
        })
        .catch((error) => {
          if (configurationRevision !== revision) return;
          set({
            configurationSaveError:
              error instanceof Error ? error.message : "Unable to save Maven configuration.",
          });
        });
    };

    const configurationDidChange = () => {
      invalidateDependencies();
      set({ reloadRequired: true, configurationSaveError: null });
      persistConfiguration();
    };

    return {
      root: null,
      visiblePaths: [],
      projectStatus: "idle",
      projectError: null,
      project: null,
      selectedProfiles: [],
      customProfiles: [],
      skipTests: false,
      settingsPath: "",
      localRepositoryPath: "",
      mavenExecutablePath: "",
      javaHomePath: "",
      configurationSaveError: null,
      reloadRequired: false,
      taskStatus: "idle",
      taskError: null,
      activeSessionId: null,
      runningTitle: null,
      output: "",
      issues: [],
      lastExitCode: null,
      dependencyLoads: {},
      activeDependencySessionId: null,
      activeDependencyModulePath: null,
      dependencyOutput: "",
      actions: {
        loadProject: async (root, visiblePaths = []) => {
          const revision = ++projectLoadRevision;
          configurationRevision += 1;
          invalidateDependencies();
          const previous = get();
          if (previous.root && previous.root !== root && previous.activeSessionId) {
            launchRevision += 1;
            diagnosticsRevision += 1;
            await dependencies.stopMavenProcess(previous.activeSessionId).catch(() => undefined);
            releaseMavenSessionWorkspace(previous.activeSessionId);
          }
          set({
            root,
            visiblePaths: [...visiblePaths],
            projectStatus: "loading",
            projectError: null,
            configurationSaveError: null,
            ...(previous.root && previous.root !== root
              ? {
                  project: null,
                  taskStatus: "idle" as const,
                  taskError: null,
                  activeSessionId: null,
                  runningTitle: null,
                  output: "",
                  issues: [],
                  lastExitCode: null,
                }
              : {}),
          });
          try {
            const project = await dependencies.scanMavenProject(root, visiblePaths);
            if (projectLoadRevision !== revision || get().root !== root) return;
            if (!project) {
              set({
                projectStatus: "ready",
                project: null,
                selectedProfiles: [],
                customProfiles: [],
                skipTests: false,
                settingsPath: "",
                localRepositoryPath: "",
                mavenExecutablePath: "",
                javaHomePath: "",
                reloadRequired: false,
              });
              return;
            }
            await configurationWriteTask.catch(() => undefined);
            if (projectLoadRevision !== revision || get().root !== root) return;
            const stored = await dependencies.loadMavenConfiguration(root, project.relativePath);
            if (projectLoadRevision !== revision || get().root !== root) return;
            const customProfiles = normalizedProfiles(stored.portable?.customProfiles ?? []);
            const knownProfiles = new Set([
              ...project.profiles.map((profile) => profile.id),
              ...customProfiles,
            ]);
            const defaultProfiles = project.profiles
              .filter((profile) => profile.isActiveByDefault)
              .map((profile) => profile.id);
            const selectedProfiles = normalizedProfiles(
              stored.portable?.selectedProfiles ?? defaultProfiles,
            ).filter((profile) => knownProfiles.has(profile));
            set({
              projectStatus: "ready",
              projectError: null,
              project,
              selectedProfiles,
              customProfiles,
              skipTests: stored.portable?.skipTests ?? false,
              settingsPath: normalizedPath(stored.local?.settingsPath),
              localRepositoryPath: normalizedPath(stored.local?.localRepositoryPath),
              mavenExecutablePath: normalizedPath(stored.local?.mavenExecutablePath),
              javaHomePath: normalizedPath(stored.local?.javaHomePath),
              reloadRequired: false,
            });
          } catch (error) {
            if (projectLoadRevision !== revision || get().root !== root) return;
            set({
              projectStatus: "failed",
              projectError:
                error instanceof Error ? error.message : "Unable to scan the Maven project.",
              project: null,
              selectedProfiles: [],
              customProfiles: [],
              skipTests: false,
              settingsPath: "",
              localRepositoryPath: "",
              mavenExecutablePath: "",
              javaHomePath: "",
            });
          }
        },

        setSelectedProfiles: (profiles) => {
          const knownProfiles = new Set(availableMavenProfiles(get()).map((profile) => profile.id));
          const selectedProfiles = normalizedProfiles(profiles).filter((profile) =>
            knownProfiles.has(profile),
          );
          if (selectedProfiles.join("\0") === get().selectedProfiles.join("\0")) return;
          set({ selectedProfiles });
          configurationDidChange();
        },

        addCustomProfile: (value) => {
          const profile = normalizedProfile(value);
          if (!profile) return false;
          const state = get();
          set({
            customProfiles: normalizedProfiles([...state.customProfiles, profile]),
            selectedProfiles: normalizedProfiles([...state.selectedProfiles, profile]),
          });
          configurationDidChange();
          return true;
        },

        restoreDefaultProfiles: () => {
          const defaults = normalizedProfiles(
            get()
              .project?.profiles.filter((profile) => profile.isActiveByDefault)
              .map((profile) => profile.id) ?? [],
          );
          if (defaults.join("\0") === get().selectedProfiles.join("\0")) return;
          set({ selectedProfiles: defaults });
          configurationDidChange();
        },

        setSkipTests: (enabled) => {
          if (get().skipTests === enabled) return;
          set({ skipTests: enabled });
          configurationDidChange();
        },

        updateLocalConfiguration: (settings) => {
          const next = {
            settingsPath: normalizedPath(settings.settingsPath),
            localRepositoryPath: normalizedPath(settings.localRepositoryPath),
            mavenExecutablePath: normalizedPath(settings.mavenExecutablePath),
            javaHomePath: normalizedPath(settings.javaHomePath),
          };
          const state = get();
          if (
            next.settingsPath === state.settingsPath &&
            next.localRepositoryPath === state.localRepositoryPath &&
            next.mavenExecutablePath === state.mavenExecutablePath &&
            next.javaHomePath === state.javaHomePath
          ) {
            return;
          }
          set(next);
          configurationDidChange();
        },

        acknowledgeReload: () => set({ reloadRequired: false }),

        runGoals: async (goals, module, title) => {
          const state = get();
          const context = mavenLaunchContext(state);
          if (!state.root || !context || goals.length === 0) return;
          const revision = ++launchRevision;
          diagnosticsRevision += 1;
          const previousSessionId = state.activeSessionId;
          if (previousSessionId) {
            await dependencies.stopMavenProcess(previousSessionId).catch(() => undefined);
            releaseMavenSessionWorkspace(previousSessionId);
          }
          const sessionId = `maven:${crypto.randomUUID()}`;
          bindMavenSessionWorkspace(sessionId, workspaceId);
          set({
            taskStatus: "running",
            taskError: null,
            activeSessionId: sessionId,
            runningTitle: title,
            output: "",
            issues: [],
            lastExitCode: null,
          });
          try {
            await dependencies.saveWorkspaceBeforeLaunch(workspaceId);
            const plan = await dependencies.createMavenLaunchPlan(
              state.root,
              context,
              goals,
              module,
            );
            const resolved = await dependencies.resolveMavenLaunch(state.root, context, plan);
            if (launchRevision !== revision || get().activeSessionId !== sessionId) {
              releaseMavenSessionWorkspace(sessionId);
              return;
            }
            const executableName = resolved.executable.split(/[\\/]/).pop() ?? "mvn";
            set({ output: `$ ${executableName} ${displayArguments(plan.arguments)}\n\n` });
            await dependencies.startMavenProcess({
              sessionId,
              executable: resolved.executable,
              arguments: plan.arguments,
              workingDirectory: resolved.workingDirectory,
              environment: resolved.environment,
            });
            if (launchRevision !== revision || get().activeSessionId !== sessionId) {
              await dependencies.stopMavenProcess(sessionId).catch(() => undefined);
              releaseMavenSessionWorkspace(sessionId);
            }
          } catch (error) {
            if (launchRevision !== revision || get().activeSessionId !== sessionId) {
              releaseMavenSessionWorkspace(sessionId);
              return;
            }
            const message =
              error instanceof Error ? error.message : "Unable to start the Maven task.";
            set({
              taskStatus: "failed",
              taskError: message,
              activeSessionId: null,
              runningTitle: null,
              lastExitCode: 1,
              output: trimOutput(`${get().output}${message}\n`),
              issues: [{ path: "", line: 1, column: null, severity: "error", message }],
            });
            releaseMavenSessionWorkspace(sessionId);
          }
        },

        stop: async () => {
          launchRevision += 1;
          diagnosticsRevision += 1;
          const sessionId = get().activeSessionId;
          if (!sessionId) return;
          set({ taskStatus: "stopping" });
          try {
            await dependencies.stopMavenProcess(sessionId);
            if (get().activeSessionId === sessionId) {
              set({
                taskStatus: "cancelled",
                taskError: null,
                activeSessionId: null,
                runningTitle: null,
                lastExitCode: null,
                output: cancelledOutput(get().output),
              });
            }
          } catch (error) {
            if (get().activeSessionId === sessionId) {
              set({
                taskStatus: "running",
                taskError:
                  error instanceof Error ? error.message : "Unable to stop the Maven task.",
              });
            }
          } finally {
            releaseMavenSessionWorkspace(sessionId);
          }
        },

        clearOutput: () => {
          diagnosticsRevision += 1;
          set((state) => ({
            output: "",
            issues: [],
            lastExitCode: null,
            taskStatus: state.taskStatus === "cancelled" ? "idle" : state.taskStatus,
          }));
        },

        appendOutput: (sessionId, chunk) => {
          if (get().activeSessionId !== sessionId) return;
          set({ output: trimOutput(get().output + chunk) });
        },

        finishProcess: (sessionId, exitCode) => {
          const state = get();
          if (state.activeSessionId !== sessionId || !state.root) return;
          const root = state.root;
          const output = state.output;
          const revision = ++diagnosticsRevision;
          if (state.taskStatus === "stopping") {
            set({
              taskStatus: "cancelled",
              taskError: null,
              activeSessionId: null,
              runningTitle: null,
              lastExitCode: null,
              output: cancelledOutput(output),
            });
            releaseMavenSessionWorkspace(sessionId);
            return;
          }
          set({
            taskStatus: exitCode === 0 ? "idle" : "failed",
            taskError: exitCode === 0 ? null : `Maven exited with code ${exitCode}.`,
            activeSessionId: null,
            runningTitle: null,
            lastExitCode: exitCode,
          });
          void dependencies
            .parseMavenDiagnostics(root, output)
            .then((issues) => {
              if (diagnosticsRevision === revision && get().root === root) set({ issues });
            })
            .catch((error) => {
              if (diagnosticsRevision !== revision || get().root !== root) return;
              set({
                taskError:
                  error instanceof Error
                    ? error.message
                    : "Unable to parse Maven build diagnostics.",
              });
            });
        },

        loadDependencies: async (rawModulePath) => {
          const modulePath = rawModulePath.trim().replace(/\\/g, "/") || ".";
          let state = get();
          if (state.dependencyLoads[modulePath]?.status === "ready") return;

          const revision = ++dependencyRevision;
          clearDependencyTimer();
          const previousSessionId = state.activeDependencySessionId;
          const previousModulePath = state.activeDependencyModulePath;
          if (previousSessionId || previousModulePath) {
            set({
              activeDependencySessionId: null,
              activeDependencyModulePath: null,
              dependencyOutput: "",
            });
            if (previousModulePath) {
              setDependencyLoad(previousModulePath, {
                status: "cancelled",
                dependencies: [],
                error: null,
              });
            }
            if (previousSessionId) {
              try {
                await dependencies.stopMavenProcess(previousSessionId);
              } catch {
                // A superseded request remains cancelled when its native process
                // completed before the stop reached the host.
              } finally {
                releaseMavenSessionWorkspace(previousSessionId);
              }
            }
          }
          if (dependencyRevision !== revision) return;

          state = get();
          const context = mavenLaunchContext(state);
          if (!state.root || !context) return;
          const root = state.root;
          const sessionId = `maven-dependency:${crypto.randomUUID()}`;
          bindMavenSessionWorkspace(sessionId, workspaceId);
          set({
            activeDependencySessionId: sessionId,
            activeDependencyModulePath: modulePath,
            dependencyOutput: "",
          });
          setDependencyLoad(modulePath, { status: "loading", dependencies: [], error: null });

          try {
            await dependencies.saveWorkspaceBeforeLaunch(workspaceId);
            const plan = await dependencies.createMavenDependencyPlan(
              root,
              context,
              modulePath === "." ? null : modulePath,
            );
            const resolved = await dependencies.resolveMavenLaunch(root, context, plan);
            if (
              dependencyRevision !== revision ||
              get().activeDependencySessionId !== sessionId
            ) {
              releaseMavenSessionWorkspace(sessionId);
              return;
            }
            dependencyTimer = dependencyScheduler.setTimer(
              () =>
                failDependencySession(
                  sessionId,
                  modulePath,
                  "Maven dependency resolution timed out after 60 seconds.",
                ),
              MAVEN_DEPENDENCY_TIMEOUT_MILLISECONDS,
            );
            await dependencies.startMavenProcess({
              sessionId,
              executable: resolved.executable,
              arguments: plan.arguments,
              workingDirectory: resolved.workingDirectory,
              environment: resolved.environment,
            });
            if (
              dependencyRevision !== revision ||
              get().activeDependencySessionId !== sessionId
            ) {
              clearDependencyTimer();
              await dependencies.stopMavenProcess(sessionId).catch(() => undefined);
              releaseMavenSessionWorkspace(sessionId);
            }
          } catch (error) {
            if (
              dependencyRevision !== revision ||
              get().activeDependencySessionId !== sessionId
            ) {
              releaseMavenSessionWorkspace(sessionId);
              return;
            }
            clearDependencyTimer();
            const message =
              error instanceof Error
                ? error.message
                : "Unable to load Maven dependencies for this module.";
            set({
              activeDependencySessionId: null,
              activeDependencyModulePath: null,
              dependencyOutput: "",
            });
            setDependencyLoad(modulePath, { status: "failed", dependencies: [], error: message });
            releaseMavenSessionWorkspace(sessionId);
          }
        },

        cancelDependencies: async (rawModulePath) => {
          const modulePath = rawModulePath.trim().replace(/\\/g, "/") || ".";
          const state = get();
          if (
            state.activeDependencyModulePath !== modulePath &&
            state.dependencyLoads[modulePath]?.status !== "loading"
          ) {
            return;
          }
          dependencyRevision += 1;
          clearDependencyTimer();
          const sessionId =
            state.activeDependencyModulePath === modulePath
              ? state.activeDependencySessionId
              : null;
          set({
            activeDependencySessionId: null,
            activeDependencyModulePath: null,
            dependencyOutput: "",
          });
          setDependencyLoad(modulePath, { status: "cancelled", dependencies: [], error: null });
          if (!sessionId) return;
          try {
            await dependencies.stopMavenProcess(sessionId);
          } catch (error) {
            const message =
              error instanceof Error
                ? error.message
                : "Unable to stop Maven dependency resolution.";
            setDependencyLoad(modulePath, { status: "failed", dependencies: [], error: message });
          } finally {
            releaseMavenSessionWorkspace(sessionId);
          }
        },

        appendDependencyOutput: (sessionId, chunk) => {
          const state = get();
          if (state.activeDependencySessionId !== sessionId || !state.activeDependencyModulePath) {
            return;
          }
          const output = (state.dependencyOutput + chunk).replace(/\r/g, "");
          if (output.length > MAXIMUM_DEPENDENCY_OUTPUT_CHARACTERS) {
            void failDependencySession(
              sessionId,
              state.activeDependencyModulePath,
              "Maven dependency output exceeded the supported limit.",
            );
            return;
          }
          set({ dependencyOutput: output });
        },

        finishDependencyProcess: async (sessionId, exitCode) => {
          const state = get();
          if (
            state.activeDependencySessionId !== sessionId ||
            !state.activeDependencyModulePath
          ) {
            return;
          }
          const revision = dependencyRevision;
          const modulePath = state.activeDependencyModulePath;
          const output = state.dependencyOutput;
          clearDependencyTimer();
          releaseMavenSessionWorkspace(sessionId);
          set({
            activeDependencySessionId: null,
            dependencyOutput: "",
          });
          if (exitCode !== 0) {
            set({ activeDependencyModulePath: null });
            setDependencyLoad(modulePath, {
              status: "failed",
              dependencies: [],
              error: `Maven dependency resolution exited with code ${exitCode}.`,
            });
            return;
          }
          try {
            const result = await dependencies.parseMavenDependencies(modulePath, output);
            if (
              dependencyRevision !== revision ||
              get().activeDependencyModulePath !== modulePath ||
              get().dependencyLoads[modulePath]?.status !== "loading"
            ) {
              return;
            }
            set({ activeDependencyModulePath: null });
            setDependencyLoad(modulePath, {
              status: "ready",
              dependencies: result.dependencies,
              error: null,
            });
          } catch (error) {
            if (
              dependencyRevision !== revision ||
              get().activeDependencyModulePath !== modulePath ||
              get().dependencyLoads[modulePath]?.status !== "loading"
            ) {
              return;
            }
            set({ activeDependencyModulePath: null });
            setDependencyLoad(modulePath, {
              status: "failed",
              dependencies: [],
              error:
                error instanceof Error
                  ? error.message
                  : "Unable to parse Maven dependencies for this module.",
            });
          }
        },
      },
    };
  });
};

export const useMavenStore = createWorkspaceScopedStore("maven", createMavenStore);

function workspaceRootKey(root: string): string {
  const normalized = root.replace(/\\/g, "/").replace(/\/$/, "");
  return /^(?:[A-Za-z]:\/|\/\/)/.test(normalized) ? normalized.toLowerCase() : normalized;
}

function mavenProjectLoadKey(root: string, workspaceId: string): string {
  return `${workspaceId}\0${workspaceRootKey(root)}`;
}

export function loadMavenProjectForWorkspace(
  root: string,
  visiblePaths: string[] = [],
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): Promise<void> {
  const key = mavenProjectLoadKey(root, workspaceId);
  const existing = mavenProjectLoads.get(key);
  if (existing) {
    if (visiblePaths.length === 0 || existing.hasVisiblePaths) return existing.task;
    return existing.task.then(() => loadMavenProjectForWorkspace(root, visiblePaths, workspaceId));
  }
  const task = useMavenStore
    .getStore(workspaceId)
    .getState()
    .actions.loadProject(root, visiblePaths)
    .finally(() => {
      if (mavenProjectLoads.get(key)?.task === task) mavenProjectLoads.delete(key);
    });
  mavenProjectLoads.set(key, { task, hasVisiblePaths: visiblePaths.length > 0 });
  return task;
}

export async function mavenLaunchContextForWorkspace(
  root: string,
  visiblePaths: string[] = [],
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): Promise<MavenLaunchContext | null> {
  const key = mavenProjectLoadKey(root, workspaceId);
  const pending = mavenProjectLoads.get(key);
  if (pending) await pending.task;
  let state = useMavenStore.getStore(workspaceId).getState();
  const rootKey = workspaceRootKey(root);
  if (
    state.root === null ||
    workspaceRootKey(state.root) !== rootKey ||
    state.projectStatus === "idle" ||
    (state.project === null && visiblePaths.length > 0)
  ) {
    await loadMavenProjectForWorkspace(root, visiblePaths, workspaceId);
    state = useMavenStore.getStore(workspaceId).getState();
  }
  return state.root && workspaceRootKey(state.root) === rootKey ? mavenLaunchContext(state) : null;
}

export function currentMavenLaunchContext(
  root: string,
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
): MavenLaunchContext | null {
  const state = useMavenStore.getStore(workspaceId).getState();
  return state.root && workspaceRootKey(state.root) === workspaceRootKey(root)
    ? mavenLaunchContext(state)
    : null;
}

export function bindMavenSessionWorkspace(sessionId: string, workspaceId?: string): void {
  mavenSessionWorkspaces.set(
    sessionId,
    workspaceId ?? workspaceRuntimeRegistry.getActiveWorkspaceId(),
  );
}

export function mavenStoreForSession(sessionId: string) {
  const workspaceId = mavenSessionWorkspaces.get(sessionId);
  return workspaceId ? useMavenStore.getStore(workspaceId) : useMavenStore;
}

export function releaseMavenSessionWorkspace(sessionId: string): void {
  mavenSessionWorkspaces.delete(sessionId);
}
