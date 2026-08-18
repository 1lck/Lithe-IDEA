import { createStore } from "zustand/vanilla";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  createLaunchPlan,
  generateRunConfiguration,
  inspectRunConfiguration,
  resolveRunConfiguration,
  updateGlobalToolchain,
  updateRunOptions,
} from "../api/run-core-api";
import {
  discoverRunToolchains,
  listJavaSources,
  resolveRunLaunch,
  startRunProcess,
  stopRunProcess,
  writeGeneratedRunDocuments,
  writeRunDocument,
  writeRunStdin,
} from "../api/run-host-api";
import {
  CURRENT_FILE_ID,
  EMPTY_GLOBAL_TOOLCHAIN,
  EMPTY_RUN_OPTIONS,
  PRIMARY_SESSION_ID,
  type GlobalToolchain,
  type JavaRuntime,
  type MavenRuntime,
  type RunConfiguration,
  type RunConfigurationStatus,
  type RunDiagnostic,
  type RunOptions,
  type RunRecoveryAction,
  type RunSaveScope,
  type RunSession,
} from "../types/run.types";
import {
  defaultGeneratedConfigurationId,
  isBlockingToolchainDiagnostic,
  mapCoreConfiguration,
  mapCoreToolchain,
  mapDiagnostics,
  mergeLaunchEnvironment,
  recoveryActionForError,
  recoveryPathFromMessage,
  selectedToolchainCandidates,
} from "../utils/run-configuration";

const MAXIMUM_OUTPUT_CHARACTERS = 500_000;
const sessionWorkspaces = new Map<string, string>();

interface RunState {
  root: string | null;
  status: RunConfigurationStatus;
  isLoading: boolean;
  isGenerating: boolean;
  recoveryAction: RunRecoveryAction;
  recoveryPath?: string;
  invalidMessage?: string;
  diagnostics: RunDiagnostic[];
  configurations: RunConfiguration[];
  selectedConfigurationId: string | null;
  defaultConfigurationId: string | null;
  primaryOutput: string;
  primaryRunning: boolean;
  primaryTitle: string | null;
  primaryExitCode: number | null;
  sessions: RunSession[];
  selectedSessionId: string | null;
  saveError: string | null;
  generationNotice: string | null;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  globalToolchain: GlobalToolchain;
  actions: {
    loadProject: (root: string) => Promise<void>;
    generate: (root: string) => Promise<void>;
    selectConfiguration: (id: string | null) => void;
    selectSession: (id: string | null) => void;
    runConfiguration: (id: string, currentFile?: string) => Promise<void>;
    stop: (sessionId?: string) => Promise<void>;
    clearOutput: (sessionId?: string) => void;
    saveOptions: (
      configuration: RunConfiguration,
      options: RunOptions,
      scope: RunSaveScope,
    ) => Promise<boolean>;
    saveToolchain: (toolchain: GlobalToolchain) => Promise<boolean>;
    writeStdin: (sessionId: string, input: string) => Promise<void>;
    appendOutput: (sessionId: string, chunk: string) => void;
    finishProcess: (sessionId: string, exitCode: number) => void;
  };
}

function trimOutput(output: string): string {
  if (output.length <= MAXIMUM_OUTPUT_CHARACTERS) return output;
  return output.slice(output.length - MAXIMUM_OUTPUT_CHARACTERS);
}

function optionsFromConfiguration(configuration: RunConfiguration): RunOptions {
  return {
    javaHomePath: configuration.javaHomePath,
    mavenExecutablePath: configuration.mavenExecutablePath,
    mavenJavaHomePath: configuration.mavenJavaHomePath,
    workingDirectoryPath: configuration.cwd,
    vmArguments: configuration.jvmArguments.join(" "),
    programArguments: configuration.programArguments.join(" "),
    environment: configuration.env,
  };
}

async function resolveConfigurations(root: string): Promise<{
  configurations: RunConfiguration[];
  diagnostics: RunDiagnostic[];
  defaultConfigurationId: string | null;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  globalToolchain: GlobalToolchain;
}> {
  const automatic = await discoverRunToolchains(root);
  const preliminary = await resolveRunConfiguration(
    root,
    selectedToolchainCandidates(automatic, EMPTY_GLOBAL_TOOLCHAIN),
  );
  const globalToolchain = mapCoreToolchain(preliminary.toolchain);
  const hasSelectedToolchain = Boolean(
    globalToolchain.javaHomePath || globalToolchain.mavenExecutablePath,
  );
  const discovered = hasSelectedToolchain
    ? await discoverRunToolchains(root, globalToolchain)
    : automatic;
  const candidates = selectedToolchainCandidates(discovered, globalToolchain);
  const resolved = hasSelectedToolchain
    ? await resolveRunConfiguration(root, candidates)
    : preliminary;
  return {
    configurations: (resolved.configurations ?? []).map(mapCoreConfiguration),
    diagnostics: mapDiagnostics(resolved.diagnostics),
    defaultConfigurationId: resolved.defaultRunConfiguration ?? null,
    discoveredJava: discovered.java,
    discoveredMaven: discovered.maven,
    globalToolchain,
  };
}

export const createRunStore = () =>
  createStore<RunState>()((set, get) => ({
    root: null,
    status: "missing",
    isLoading: false,
    isGenerating: false,
    recoveryAction: "regenerate",
    diagnostics: [],
    configurations: [],
    selectedConfigurationId: null,
    defaultConfigurationId: null,
    primaryOutput: "",
    primaryRunning: false,
    primaryTitle: null,
    primaryExitCode: null,
    sessions: [],
    selectedSessionId: null,
    saveError: null,
    generationNotice: null,
    discoveredJava: [],
    discoveredMaven: [],
    globalToolchain: EMPTY_GLOBAL_TOOLCHAIN,
    actions: {
      loadProject: async (root) => {
        set({
          root,
          isLoading: true,
          saveError: null,
          generationNotice: null,
        });
        try {
          const inspection = await inspectRunConfiguration(root);
          if (inspection.status !== "ready") {
            set({
              status: "missing",
              recoveryAction: "regenerate",
              diagnostics: mapDiagnostics(inspection.diagnostics),
              configurations: [],
              isLoading: false,
            });
            return;
          }
          const resolved = await resolveConfigurations(root);
          const selectedConfigurationId =
            get().selectedConfigurationId &&
            resolved.configurations.some((configuration) => configuration.id === get().selectedConfigurationId)
              ? get().selectedConfigurationId
              : resolved.defaultConfigurationId ??
                resolved.configurations.find((configuration) => configuration.id !== CURRENT_FILE_ID)?.id ??
                null;
          set({
            status: "ready",
            recoveryAction: "none",
            recoveryPath: undefined,
            invalidMessage: undefined,
            diagnostics: [...mapDiagnostics(inspection.diagnostics), ...resolved.diagnostics],
            configurations: resolved.configurations,
            selectedConfigurationId,
            defaultConfigurationId: resolved.defaultConfigurationId,
            discoveredJava: resolved.discoveredJava,
            discoveredMaven: resolved.discoveredMaven,
            globalToolchain: resolved.globalToolchain,
            isLoading: false,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Project run configuration is invalid";
          const code = error instanceof Error ? (error as Error & { code?: string }).code : undefined;
          set({
            status: "invalid",
            invalidMessage: message,
            recoveryAction: recoveryActionForError(code),
            recoveryPath: recoveryPathFromMessage(message),
            configurations: [],
            isLoading: false,
          });
        }
      },

      generate: async (root) => {
        set({ isGenerating: true, isLoading: true, generationNotice: null, saveError: null });
        try {
          const paths = await listJavaSources(root);
          const generated = await generateRunConfiguration(root, paths);
          await writeGeneratedRunDocuments({
            root,
            generated: generated.generated,
            toolchainRequirements: generated.toolchainRequirements,
            defaultRunConfiguration: defaultGeneratedConfigurationId(generated.generated),
          });
          const resolved = await resolveConfigurations(root);
          const notice =
            generated.entryCount === 0
              ? "no-entries"
              : `generated:${generated.entryCount}`;
          set({
            root,
            status: "ready",
            recoveryAction: "none",
            recoveryPath: undefined,
            invalidMessage: undefined,
            diagnostics: resolved.diagnostics,
            configurations: resolved.configurations,
            selectedConfigurationId:
              resolved.defaultConfigurationId ??
              resolved.configurations.find((configuration) => configuration.id !== CURRENT_FILE_ID)?.id ??
              null,
            defaultConfigurationId: resolved.defaultConfigurationId,
            discoveredJava: resolved.discoveredJava,
            discoveredMaven: resolved.discoveredMaven,
            globalToolchain: resolved.globalToolchain,
            generationNotice: notice,
            isGenerating: false,
            isLoading: false,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Project identification failed";
          set({
            status: "invalid",
            invalidMessage: message,
            recoveryAction: "fixPermissions",
            generationNotice: `failed:${message}`,
            isGenerating: false,
            isLoading: false,
          });
        }
      },

      selectConfiguration: (id) => set({ selectedConfigurationId: id, selectedSessionId: id }),
      selectSession: (id) => set({ selectedSessionId: id }),

      runConfiguration: async (id, currentFile) => {
        const state = get();
        const root = state.root;
        const configuration = state.configurations.find((item) => item.id === id);
        if (!root || !configuration) return;
        const blocking = state.diagnostics.find(isBlockingToolchainDiagnostic);
        if (blocking) {
          set({
            primaryOutput: trimOutput(`${state.primaryOutput}${blocking.message}\n`),
            primaryRunning: false,
            primaryExitCode: 1,
          });
          return;
        }
        if (configuration.id === CURRENT_FILE_ID && !currentFile) {
          set({
            primaryOutput: trimOutput(`${state.primaryOutput}Open a source file before running Current File.\n`),
            primaryRunning: false,
            primaryExitCode: 1,
          });
          return;
        }
        const sessionId = configuration.execution === "service" ? configuration.id : PRIMARY_SESSION_ID;
        bindRunSessionWorkspace(sessionId);
        await stopRunProcess(sessionId).catch(() => undefined);
        try {
          const plan = await createLaunchPlan(root, configuration.id, currentFile);
          const resolved = await resolveRunLaunch({
            root,
            executable: plan.executable,
            workingDirectory: plan.workingDirectory,
            javaHomePath: configuration.javaHomePath,
            mavenExecutablePath: configuration.mavenExecutablePath,
            mavenJavaHomePath: configuration.mavenJavaHomePath,
            environment: mergeLaunchEnvironment(configuration.env, plan),
          });
          const commandLine = `$ ${resolved.executable.split(/[\\/]/).pop()} ${plan.arguments.join(" ")}\n\n`;
          if (sessionId === PRIMARY_SESSION_ID) {
            set({
              primaryRunning: true,
              primaryTitle: configuration.name,
              primaryExitCode: null,
              primaryOutput: commandLine,
              selectedSessionId: null,
            });
          } else {
            set((current) => ({
              selectedSessionId: sessionId,
              sessions: [
                ...current.sessions.filter((session) => session.id !== sessionId),
                {
                  id: sessionId,
                  configurationId: configuration.id,
                  title: configuration.name,
                  output: commandLine,
                  isRunning: true,
                  exitCode: null,
                },
              ],
            }));
          }
          await startRunProcess({
            sessionId,
            executable: resolved.executable,
            arguments: plan.arguments,
            workingDirectory: resolved.workingDirectory,
            environment: resolved.environment,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : "Unable to start the run configuration.";
          if (sessionId === PRIMARY_SESSION_ID) {
            set({
              primaryRunning: false,
              primaryExitCode: 1,
              primaryOutput: trimOutput(`${get().primaryOutput}${message}\n`),
            });
          } else {
            set((current) => ({
              sessions: current.sessions.map((session) =>
                session.id === sessionId
                  ? { ...session, isRunning: false, exitCode: 1, output: trimOutput(`${session.output}${message}\n`) }
                  : session,
              ),
            }));
          }
        }
      },

      stop: async (sessionId) => {
        const target = sessionId ?? get().selectedSessionId ?? PRIMARY_SESSION_ID;
        await stopRunProcess(target).catch(() => undefined);
        if (target === PRIMARY_SESSION_ID) {
          set({ primaryRunning: false });
        } else {
          set((current) => ({
            sessions: current.sessions.map((session) =>
              session.id === target ? { ...session, isRunning: false } : session,
            ),
          }));
        }
      },

      clearOutput: (sessionId) => {
        const target = sessionId ?? get().selectedSessionId;
        if (!target || target === PRIMARY_SESSION_ID) {
          set({ primaryOutput: "", primaryExitCode: null });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === target ? { ...session, output: "", exitCode: null } : session,
          ),
        }));
      },

      saveOptions: async (configuration, options, scope) => {
        const root = get().root;
        if (!root) return false;
        try {
          const mutation = await updateRunOptions(root, configuration.id, scope, options);
          await writeRunDocument(
            root,
            scope === "local" ? "run/local.json" : "run/configurations.json",
            mutation.document,
          );
          await get().actions.loadProject(root);
          set({ saveError: null });
          return true;
        } catch (error) {
          set({
            saveError: error instanceof Error ? error.message : "Could not save the run configuration.",
          });
          return false;
        }
      },

      saveToolchain: async (toolchain) => {
        const root = get().root;
        if (!root) return false;
        try {
          const mutation = await updateGlobalToolchain(root, toolchain);
          await writeRunDocument(root, "run/local.json", mutation.document);
          await get().actions.loadProject(root);
          set({ saveError: null });
          return true;
        } catch (error) {
          set({
            saveError: error instanceof Error ? error.message : "Could not save the toolchain.",
          });
          return false;
        }
      },

      writeStdin: async (sessionId, input) => {
        try {
          await writeRunStdin(sessionId, input);
        } catch (error) {
          const message = error instanceof Error ? error.message : "Could not write to process input.";
          get().actions.appendOutput(sessionId, `${message}\n`);
        }
      },

      appendOutput: (sessionId, chunk) => {
        if (sessionId === PRIMARY_SESSION_ID) {
          set({ primaryOutput: trimOutput(get().primaryOutput + chunk) });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === sessionId ? { ...session, output: trimOutput(session.output + chunk) } : session,
          ),
        }));
      },

      finishProcess: (sessionId, exitCode) => {
        if (sessionId === PRIMARY_SESSION_ID) {
          set({ primaryRunning: false, primaryExitCode: exitCode });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === sessionId ? { ...session, isRunning: false, exitCode } : session,
          ),
        }));
      },
    },
  }));

export const useRunStore = createWorkspaceScopedStore("run", createRunStore);

export function bindRunSessionWorkspace(sessionId: string, workspaceId?: string): void {
  sessionWorkspaces.set(
    sessionId,
    workspaceId ?? workspaceRuntimeRegistry.getActiveWorkspaceId(),
  );
}

export function runStoreForSession(sessionId: string) {
  const workspaceId = sessionWorkspaces.get(sessionId);
  return workspaceId ? useRunStore.getStore(workspaceId) : useRunStore;
}

export function releaseRunSessionWorkspace(sessionId: string): void {
  sessionWorkspaces.delete(sessionId);
}

export function runOptionsFor(configuration: RunConfiguration): RunOptions {
  return optionsFromConfiguration(configuration);
}

export { EMPTY_RUN_OPTIONS };
