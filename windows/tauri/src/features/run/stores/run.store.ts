import { createStore } from "zustand/vanilla";
import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { createWorkspaceScopedStore } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { mavenLaunchContextForWorkspace } from "@/features/maven/stores/maven.store";
import {
  createLaunchPlan,
  generateRunConfiguration,
  inspectRunConfiguration,
  saveRunConfigurationEditorChanges,
} from "../api/run-core-api";
import {
  executePreLaunchStep,
  listJavaSources,
  resolveRunLaunch,
  startRunProcess,
  stopRunProcess,
  writeGeneratedRunDocuments,
  writeRunDocuments,
  writeRunStdin,
} from "../api/run-host-api";
import {
  CURRENT_FILE_ID,
  EMPTY_GLOBAL_TOOLCHAIN,
  EMPTY_RUN_OPTIONS,
  PRIMARY_SESSION_ID,
  type GenericRuntime,
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
  type RunProcessInstance,
} from "../types/run.types";
import {
  defaultGeneratedConfigurationId,
  blockingToolchainDiagnosticForConfiguration,
  mapDiagnostics,
  mergeLaunchEnvironment,
  recoveryActionForError,
  recoveryPathFromMessage,
  configurationUsesMaven,
} from "../utils/run-configuration";
import { editorSaveFailureMessage, runEditorSaveWorkflow } from "../services/run-editor-save";
import { prepareJavaRunLaunch, usesJavaProjectPreparation } from "../services/java-run-launch";
import {
  discoverJavaEntrypoints,
  whenJavaProjectPrepared,
} from "../services/java-entrypoint-discovery";
import { rebuildJavaIndexForWorkspace } from "@/features/editor/lsp/java-index-recovery";
import type { JavaBuildFailure } from "@/platform/java-launch-readiness";
import {
  javaBuildFailurePolicyForWorkspace,
  useRunPreferencesStore,
} from "./run-preferences.store";
import {
  createOutputStamper,
  trimRunOutput,
  type OutputStamper,
} from "../utils/output-timestamper";
import { resolveConfigurations, type ResolvedRunProject } from "../services/resolve-run-project";
import { frontendTrace } from "@/utils/frontend-trace";
import { openRunDecisionPane } from "../actions/run-tool-window-actions";

const MAXIMUM_OUTPUT_CHARACTERS = 500_000;
const sessionWorkspaces = new Map<string, string>();
const outputStampers = new Map<string, OutputStamper>();
const workspaceSaveInFlight = new Map<string, Promise<void>>();

export interface JavaLaunchDecision {
  decisionId: string;
  sessionId: string;
  configurationId: string;
  configurationName: string;
  failure: JavaBuildFailure;
}

/**
 * Where the Java entries in the Run list come from.
 *
 * `ready` is JDT's current answer; `stale` shows the previous answer while the
 * Java service prepares the project; `loading` has no previous answer yet;
 * `failed` keeps the previous list and reports why it could not refresh.
 */
export type JavaDiscoveryStatus = "idle" | "loading" | "ready" | "stale" | "failed";

interface RunState {
  root: string | null;
  javaDiscovery: JavaDiscoveryStatus;
  javaDiscoveryMessage: string | null;
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
  /** Configuration whose editor is open, requested from the Run pane or the editor gutter. */
  editingConfigurationId: string | null;
  generationNotice: string | null;
  javaLaunchDecisions: Record<string, JavaLaunchDecision>;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  discoveredRuntimes: GenericRuntime[];
  globalToolchain: GlobalToolchain;
  effectiveRuntimeExecutablePaths: Record<string, string>;
  actions: {
    loadProject: (root: string) => Promise<void>;
    generate: (root: string) => Promise<void>;
    selectConfiguration: (id: string | null) => void;
    selectSession: (id: string | null) => void;
    editConfiguration: (id: string | null) => void;
    runConfiguration: (
      id: string,
      currentFile?: string,
      debugPort?: number,
    ) => Promise<string | null>;
    runConfigurationInstance: (
      id: string,
      currentFile?: string,
      debugPort?: number,
    ) => Promise<RunProcessInstance | null>;
    continueJavaLaunch: (sessionId: string, decisionId: string, remember: boolean) => void;
    cancelJavaLaunch: (sessionId: string, decisionId?: string) => void;
    rebuildJavaIndex: (sessionId: string, decisionId: string) => Promise<void>;
    stop: (sessionId?: string, executionId?: string) => Promise<void>;
    clearOutput: (sessionId?: string) => void;
    saveEditorChanges: (
      configuration: RunConfiguration,
      options: RunOptions,
      toolchain: GlobalToolchain,
      scope: RunSaveScope,
    ) => Promise<boolean>;
    writeStdin: (sessionId: string, input: string) => Promise<void>;
    appendOutput: (sessionId: string, chunk: string) => void;
    finishProcess: (sessionId: string, exitCode: number) => void;
  };
}

export interface RunStoreDependencies {
  inspectRunConfiguration?: typeof inspectRunConfiguration;
  resolveConfigurations?: typeof resolveConfigurations;
  createLaunchPlan: typeof createLaunchPlan;
  mavenLaunchContextForWorkspace: typeof mavenLaunchContextForWorkspace;
  resolveRunLaunch: typeof resolveRunLaunch;
  executePreLaunchStep: typeof executePreLaunchStep;
  saveWorkspaceBeforeLaunch: typeof saveWorkspaceBeforeLaunch;
  startRunProcess: typeof startRunProcess;
  stopRunProcess: typeof stopRunProcess;
  prepareJavaRunLaunch: typeof prepareJavaRunLaunch;
  rebuildJavaIndexForWorkspace?: typeof rebuildJavaIndexForWorkspace;
  javaBuildFailurePolicyForWorkspace?: typeof javaBuildFailurePolicyForWorkspace;
  setJavaBuildFailurePolicy?: (workspace: string, policy: "ask" | "alwaysProceed") => void;
  presentJavaLaunchDecision?: (workspaceId: string) => void;
  discoverJavaEntrypoints?: typeof discoverJavaEntrypoints;
  whenJavaProjectPrepared?: typeof whenJavaProjectPrepared;
  listJavaSources?: typeof listJavaSources;
  generateRunConfiguration?: typeof generateRunConfiguration;
  writeGeneratedRunDocuments?: typeof writeGeneratedRunDocuments;
}

const defaultRunStoreDependencies: RunStoreDependencies = {
  createLaunchPlan,
  mavenLaunchContextForWorkspace,
  resolveRunLaunch,
  executePreLaunchStep,
  saveWorkspaceBeforeLaunch,
  startRunProcess,
  stopRunProcess,
  prepareJavaRunLaunch,
  rebuildJavaIndexForWorkspace,
  javaBuildFailurePolicyForWorkspace,
  setJavaBuildFailurePolicy: (workspace, policy) =>
    useRunPreferencesStore.getState().actions.setJavaBuildFailurePolicy(workspace, policy),
  presentJavaLaunchDecision: openRunDecisionPane,
};

// Classpath joining is the host's job: Rust emits a platform-neutral list and
// the host joins it with `;` on Windows. JVM options may precede the main class
// in any order.
/// Reads the failure the host reported.
///
/// A Tauri command that fails rejects with the plain string its Rust handler
/// returned, so an `instanceof Error` check alone discards the operating
/// system's reason, such as a command line refused for its length.
function launchFailureMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim()) return error.message;
  if (typeof error === "string" && error.trim()) return error;
  const message = (error as { message?: unknown } | null)?.message;
  if (typeof message === "string" && message.trim()) return message;
  return "Unable to start the run configuration.";
}

const CLASSPATH_SEPARATOR = ";";
// Core may first wait for JDT Maven project updates and an earlier build, which
// can take minutes on a cold multi-module project.
const JAVA_PREPARATION_NOTICE =
  "Preparing the Java launch: waiting for the Java language service to update and build the project...\n";
const JAVA_BUILD_CONTINUE_NOTICE =
  "Continuing with the Java output currently available on disk.\n\n";
const CLASSPATH_FLAGS = new Set(["-cp", "-classpath", "--class-path"]);
// Merges the launch classpath into `args`. When the user already passes a
// `-cp`/`-classpath`/`--class-path`, our entries are prepended into that same
// flag's value (the compiled output must lead, and a second `-cp` would simply
// override the user's — the JVM honors only the last one). Otherwise a fresh
// `-cp` is inserted before the arguments.
function withJavaPaths(args: string[], classpath?: string[], modulepath?: string[]): string[] {
  const withClasspath = mergeJavaPath(args, classpath, CLASSPATH_FLAGS, "-cp");
  return mergeJavaPath(
    withClasspath,
    modulepath,
    new Set(["-p", "--module-path"]),
    "--module-path",
  );
}

function mergeJavaPath(
  args: string[],
  paths: string[] | undefined,
  flags: Set<string>,
  defaultFlag: string,
): string[] {
  if (!paths || paths.length === 0) return args;
  const joined = paths.join(CLASSPATH_SEPARATOR);
  // Merge into the last existing flag: that is the value the JVM would use.
  for (let index = args.length - 2; index >= 0; index -= 1) {
    if (flags.has(args[index])) {
      const merged = [...args];
      merged[index + 1] = `${joined}${CLASSPATH_SEPARATOR}${args[index + 1]}`;
      return merged;
    }
  }
  return [defaultFlag, joined, ...args];
}

type RunProjectSnapshot =
  | { status: "missing"; diagnostics: RunDiagnostic[] }
  | ({ status: "ready" } & ResolvedRunProject);

type ReadyRunState = Pick<
  RunState,
  | "status"
  | "recoveryAction"
  | "recoveryPath"
  | "invalidMessage"
  | "diagnostics"
  | "configurations"
  | "selectedConfigurationId"
  | "defaultConfigurationId"
  | "discoveredJava"
  | "discoveredMaven"
  | "discoveredRuntimes"
  | "globalToolchain"
  | "effectiveRuntimeExecutablePaths"
  | "isLoading"
>;

function trimOutput(output: string): string {
  return trimRunOutput(output, MAXIMUM_OUTPUT_CHARACTERS);
}

function stamperFor(sessionId: string): OutputStamper {
  let stamper = outputStampers.get(sessionId);
  if (!stamper) {
    stamper = createOutputStamper();
    outputStampers.set(sessionId, stamper);
  }
  return stamper;
}

function resetOutputStamper(sessionId: string): void {
  stamperFor(sessionId).reset();
}

function appendStampedOutput(sessionId: string, existing: string, chunk: string): string {
  return trimOutput(existing + stamperFor(sessionId).push(chunk));
}

function flushStampedOutput(sessionId: string, existing: string): string {
  return trimOutput(existing + stamperFor(sessionId).flush());
}

function optionsFromConfiguration(configuration: RunConfiguration): RunOptions {
  return {
    javaHomePath: configuration.javaHomePath,
    mavenExecutablePath: configuration.mavenExecutablePath,
    mavenJavaHomePath: configuration.mavenJavaHomePath,
    mavenSkipTests: configuration.mavenSkipTests,
    workingDirectoryPath: configuration.cwd,
    vmArguments: configuration.jvmArguments.join(" "),
    programArguments: configuration.programArguments.join(" "),
    environment: configuration.env,
  };
}

async function readRunProjectSnapshot(
  root: string,
  workspaceId: string,
  dependencies: RunStoreDependencies,
): Promise<RunProjectSnapshot> {
  const inspection = await (dependencies.inspectRunConfiguration ?? inspectRunConfiguration)(root);
  const inspectionDiagnostics = mapDiagnostics(inspection.diagnostics);
  if (inspection.status !== "ready") {
    return { status: "missing", diagnostics: inspectionDiagnostics };
  }
  const resolved = await (dependencies.resolveConfigurations ?? resolveConfigurations)(root, workspaceId);
  return {
    status: "ready",
    ...resolved,
    diagnostics: [...inspectionDiagnostics, ...resolved.diagnostics],
  };
}

function readyRunState(
  snapshot: Extract<RunProjectSnapshot, { status: "ready" }>,
  currentSelection: string | null,
): ReadyRunState {
  const selectedConfigurationId =
    currentSelection &&
    snapshot.configurations.some((configuration) => configuration.id === currentSelection)
      ? currentSelection
      : (snapshot.defaultConfigurationId ??
        snapshot.configurations.find((configuration) => configuration.id !== CURRENT_FILE_ID)?.id ??
        null);
  return {
    status: "ready",
    recoveryAction: "none",
    recoveryPath: undefined,
    invalidMessage: undefined,
    diagnostics: snapshot.diagnostics,
    configurations: snapshot.configurations,
    selectedConfigurationId,
    defaultConfigurationId: snapshot.defaultConfigurationId,
    discoveredJava: snapshot.discoveredJava,
    discoveredMaven: snapshot.discoveredMaven,
    discoveredRuntimes: snapshot.discoveredRuntimes,
    globalToolchain: snapshot.globalToolchain,
    effectiveRuntimeExecutablePaths: snapshot.effectiveRuntimeExecutablePaths,
    isLoading: false,
  };
}

export const createRunStore = (
  workspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId(),
  overrides: Partial<RunStoreDependencies> = {},
) => {
  const dependencies = { ...defaultRunStoreDependencies, ...overrides };
  const buildFailurePolicy =
    dependencies.javaBuildFailurePolicyForWorkspace ?? javaBuildFailurePolicyForWorkspace;
  const setBuildFailurePolicy =
    dependencies.setJavaBuildFailurePolicy ??
    ((workspace, policy) =>
      useRunPreferencesStore.getState().actions.setJavaBuildFailurePolicy(workspace, policy));
  const rebuildJavaIndex =
    dependencies.rebuildJavaIndexForWorkspace ?? rebuildJavaIndexForWorkspace;
  const presentJavaLaunchDecision =
    dependencies.presentJavaLaunchDecision ?? openRunDecisionPane;
  const executions = new Map<string, string>();
  const pendingJavaLaunchDecisions = new Map<
    string,
    { decisionId: string; executionId: string; resolve: (proceed: boolean) => void }
  >();
  let projectLoadRevision = 0;
  // At most one pending refresh: a newer generation or project load replaces it.
  let stopWaitingForJavaProject: (() => void) | null = null;
  const cancelJavaRefresh = () => {
    stopWaitingForJavaProject?.();
    stopWaitingForJavaProject = null;
  };
  return createStore<RunState>()((set, get) => ({
    root: null,
    javaDiscovery: "idle",
    javaDiscoveryMessage: null,
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
    editingConfigurationId: null,
    generationNotice: null,
    javaLaunchDecisions: {},
    discoveredJava: [],
    discoveredMaven: [],
    discoveredRuntimes: [],
    globalToolchain: EMPTY_GLOBAL_TOOLCHAIN,
    effectiveRuntimeExecutablePaths: {},
    actions: {
      loadProject: async (root) => {
        cancelJavaRefresh();
        for (const pending of pendingJavaLaunchDecisions.values()) pending.resolve(false);
        pendingJavaLaunchDecisions.clear();
        const revision = ++projectLoadRevision;
        set({
          root,
          isLoading: true,
          isGenerating: false,
          saveError: null,
          editingConfigurationId: root === get().root ? get().editingConfigurationId : null,
          generationNotice: null,
          javaLaunchDecisions: {},
        });
        try {
          const snapshot = await readRunProjectSnapshot(root, workspaceId, dependencies);
          if (revision !== projectLoadRevision || get().root !== root) return;
          if (snapshot.status === "missing") {
            set({
              status: "missing",
              recoveryAction: "regenerate",
              diagnostics: snapshot.diagnostics,
              configurations: [],
              isLoading: false,
            });
            return;
          }
          set(readyRunState(snapshot, get().selectedConfigurationId));
        } catch (error) {
          if (revision !== projectLoadRevision || get().root !== root) return;
          const message =
            error instanceof Error ? error.message : "Project run configuration is invalid";
          const code =
            error instanceof Error ? (error as Error & { code?: string }).code : undefined;
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
        cancelJavaRefresh();
        const revision = ++projectLoadRevision;
        const isCurrent = () => revision === projectLoadRevision && get().root === root;
        set({
          root,
          isGenerating: true,
          isLoading: true,
          generationNotice: null,
          saveError: null,
        });
        try {
          const paths = await (dependencies.listJavaSources ?? listJavaSources)(root);
          if (!isCurrent()) return;
          // JDT decides which classes are launchable. Until it has prepared
          // the project, Core keeps the previous generation's Java entries.
          const discovery =
            paths.length === 0
              ? null
              : await (dependencies.discoverJavaEntrypoints ?? discoverJavaEntrypoints)(
                  { workspaceId, root },
                  paths,
                );
          if (!isCurrent()) return;
          const generated = await (dependencies.generateRunConfiguration ?? generateRunConfiguration)(
            root,
            paths,
            [],
            discovery?.kind === "discovered" ? discovery.entrypoints : undefined,
          );
          if (!isCurrent()) return;
          await (dependencies.writeGeneratedRunDocuments ?? writeGeneratedRunDocuments)({
            root,
            generated: generated.generated,
            toolchainRequirements: generated.toolchainRequirements,
            defaultRunConfiguration: defaultGeneratedConfigurationId(generated.generated),
          });
          if (!isCurrent()) return;
          const resolved = await (dependencies.resolveConfigurations ?? resolveConfigurations)(root, workspaceId);
          if (!isCurrent()) return;
          const notice =
            generated.entryCount === 0 ? "no-entries" : `generated:${generated.entryCount}`;
          const hasJavaEntries = resolved.configurations.some(
            (configuration) => configuration.provider === "java.main",
          );
          const javaDiscovery: JavaDiscoveryStatus =
            discovery === null
              ? "idle"
              : discovery.kind === "discovered"
                ? "ready"
                : discovery.kind === "failed"
                  ? "failed"
                  : hasJavaEntries
                    ? "stale"
                    : "loading";
          if (discovery?.kind === "pending") {
            stopWaitingForJavaProject = (
              dependencies.whenJavaProjectPrepared ?? whenJavaProjectPrepared
            )(root, () => {
              stopWaitingForJavaProject = null;
              if (get().root === root) void get().actions.generate(root);
            });
          }
          set({
            root,
            javaDiscovery,
            javaDiscoveryMessage: discovery?.kind === "failed" ? discovery.message : null,
            status: "ready",
            recoveryAction: "none",
            recoveryPath: undefined,
            invalidMessage: undefined,
            diagnostics: resolved.diagnostics,
            configurations: resolved.configurations,
            selectedConfigurationId:
              resolved.defaultConfigurationId ??
              resolved.configurations.find((configuration) => configuration.id !== CURRENT_FILE_ID)
                ?.id ??
              null,
            defaultConfigurationId: resolved.defaultConfigurationId,
            discoveredJava: resolved.discoveredJava,
            discoveredMaven: resolved.discoveredMaven,
            discoveredRuntimes: resolved.discoveredRuntimes,
            globalToolchain: resolved.globalToolchain,
            effectiveRuntimeExecutablePaths: resolved.effectiveRuntimeExecutablePaths,
            generationNotice: notice,
            isGenerating: false,
            isLoading: false,
          });
        } catch (error) {
          if (!isCurrent()) return;
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
      editConfiguration: (id) => set({ editingConfigurationId: id }),

      runConfiguration: async (id, currentFile, debugPort) => {
        const instance = await get().actions.runConfigurationInstance(id, currentFile, debugPort);
        return instance?.sessionId ?? null;
      },

      runConfigurationInstance: async (id, currentFile, debugPort) => {
        const state = get();
        const root = state.root;
        const configuration = state.configurations.find((item) => item.id === id);
        if (!root || !configuration) return null;
        const blocking = blockingToolchainDiagnosticForConfiguration(
          state.diagnostics,
          configuration.id,
        );
        if (blocking) {
          set({
            primaryOutput: trimOutput(`${state.primaryOutput}${blocking.message}\n`),
            primaryRunning: false,
            primaryExitCode: 1,
          });
          return null;
        }
        if (configuration.id === CURRENT_FILE_ID && !currentFile) {
          set({
            primaryOutput: trimOutput(
              `${state.primaryOutput}Open a source file before running Current File.\n`,
            ),
            primaryRunning: false,
            primaryExitCode: 1,
          });
          return null;
        }
        const sessionId =
          configuration.execution === "service" ? configuration.id : PRIMARY_SESSION_ID;
        const previousDecision = pendingJavaLaunchDecisions.get(sessionId);
        if (previousDecision) {
          pendingJavaLaunchDecisions.delete(sessionId);
          previousDecision.resolve(false);
          set((current) => {
            const javaLaunchDecisions = { ...current.javaLaunchDecisions };
            delete javaLaunchDecisions[sessionId];
            return { javaLaunchDecisions };
          });
        }
        const executionId = crypto.randomUUID();
        // Reserve ownership before yielding so old Debug callbacks cannot stop a replacement.
        executions.set(sessionId, executionId);
        const isCurrent = () => executions.get(sessionId) === executionId && get().root === root;
        bindRunSessionWorkspace(sessionId, workspaceId);
        resetOutputStamper(sessionId);
        await dependencies.stopRunProcess(sessionId).catch(() => undefined);
        try {
          if (!isCurrent()) return null;
          let save = workspaceSaveInFlight.get(workspaceId);
          if (!save) {
            save = dependencies.saveWorkspaceBeforeLaunch(workspaceId);
            workspaceSaveInFlight.set(workspaceId, save);
            const clearSave = () => {
              if (workspaceSaveInFlight.get(workspaceId) === save) workspaceSaveInFlight.delete(workspaceId);
            };
            void save.then(clearSave, clearSave);
          }
          await save;
          if (!isCurrent()) return null;
          const mavenContext = configurationUsesMaven(configuration)
            ? await dependencies.mavenLaunchContextForWorkspace(root, [], workspaceId)
            : null;
          if (!isCurrent()) return null;
          if (usesJavaProjectPreparation(configuration)) {
            // Show the wait in the session panel so a long first build does not
            // look like an unresponsive Run action. The launch replaces this
            // text with its command line; a failure is appended after it.
            if (sessionId === PRIMARY_SESSION_ID) {
              set({
                primaryTitle: configuration.name,
                primaryExitCode: null,
                primaryOutput: JAVA_PREPARATION_NOTICE,
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
                    output: JAVA_PREPARATION_NOTICE,
                    isRunning: false,
                    exitCode: null,
                  },
                ],
              }));
            }
          }
          const javaPreparation = await dependencies.prepareJavaRunLaunch(
            { workspaceId, root },
            configuration,
          );
          if (!isCurrent()) return null;
          const javaLaunch = javaPreparation?.target ?? null;
          let javaBuildWarning = "";
          if (javaPreparation?.kind === "buildFailed") {
            const { failure } = javaPreparation;
            const buildMessage = `${failure.message}\n`;
            if (sessionId === PRIMARY_SESSION_ID) {
              set((current) => ({
                primaryOutput: trimOutput(`${current.primaryOutput}${buildMessage}`),
              }));
            } else {
              set((current) => ({
                sessions: current.sessions.map((session) =>
                  session.id === sessionId
                    ? { ...session, output: trimOutput(`${session.output}${buildMessage}`) }
                    : session,
                ),
              }));
            }

            const policy = buildFailurePolicy(root);
            if (policy !== "alwaysProceed") {
              const decisionId = crypto.randomUUID();
              const decision = new Promise<boolean>((resolve) => {
                pendingJavaLaunchDecisions.set(sessionId, {
                  decisionId,
                  executionId,
                  resolve,
                });
              });
              set((current) => ({
                javaLaunchDecisions: {
                  ...current.javaLaunchDecisions,
                  [sessionId]: {
                    decisionId,
                    sessionId,
                    configurationId: configuration.id,
                    configurationName: configuration.name,
                    failure,
                  },
                },
              }));
              presentJavaLaunchDecision(workspaceId);
              const proceed = await decision;
              if (!isCurrent() || !proceed) {
                if (isCurrent()) executions.delete(sessionId);
                return null;
              }
            }
            javaBuildWarning = `${buildMessage}${JAVA_BUILD_CONTINUE_NOTICE}`;
          }
          const plan = await dependencies.createLaunchPlan(
            root,
            configuration.id,
            currentFile,
            mavenContext,
            debugPort,
            javaLaunch,
          );
          if (!isCurrent()) return null;
          const resolved = await dependencies.resolveRunLaunch({
            root,
            executable: plan.executable,
            workingDirectory: plan.workingDirectory,
            javaHomePath: configuration.javaHomePath,
            mavenExecutablePath:
              configuration.mavenExecutablePath || mavenContext?.mavenExecutablePath || "",
            mavenJavaHomePath:
              configuration.mavenJavaHomePath || mavenContext?.javaHomePath || "",
            runtimeExecutablePaths: state.effectiveRuntimeExecutablePaths,
            environment: mergeLaunchEnvironment(configuration.env, plan),
          });
          if (!isCurrent()) return null;
          const mainArguments = withJavaPaths(plan.arguments, plan.classpath, plan.modulepath);
          const commandLine = `$ ${resolved.executable.split(/[\\/]/).pop()} ${mainArguments.join(" ")}\n\n`;
          if (sessionId === PRIMARY_SESSION_ID) {
            set({
              primaryRunning: true,
              primaryTitle: configuration.name,
              primaryExitCode: null,
              primaryOutput: trimOutput(`${commandLine}${javaBuildWarning}`),
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
                  output: trimOutput(`${commandLine}${javaBuildWarning}`),
                  isRunning: true,
                  exitCode: null,
                },
              ],
            }));
          }
          // Appends compiler/generator output into the same session panel the
          // main process streams into, so pre-launch diagnostics stay in place.
          const appendSessionOutput = (text: string) => {
            if (sessionId === PRIMARY_SESSION_ID) {
              set((current) => ({
                primaryOutput: trimOutput(`${current.primaryOutput}${text}`),
              }));
            } else {
              set((current) => ({
                sessions: current.sessions.map((session) =>
                  session.id === sessionId
                    ? { ...session, output: trimOutput(`${session.output}${text}`) }
                    : session,
                ),
              }));
            }
          };
          const markPreLaunchFailure = (exitCode: number) => {
            const message = `Compilation failed (exit code ${exitCode}).\n`;
            if (sessionId === PRIMARY_SESSION_ID) {
              set((current) => ({
                primaryRunning: false,
                primaryExitCode: exitCode,
                primaryOutput: trimOutput(`${current.primaryOutput}${message}`),
              }));
            } else {
              set((current) => ({
                sessions: current.sessions.map((session) =>
                  session.id === sessionId
                    ? {
                        ...session,
                        isRunning: false,
                        exitCode,
                        output: trimOutput(`${session.output}${message}`),
                      }
                    : session,
                ),
              }));
            }
          };
          // Compile-then-run: standalone Java compiles with `javac` here so JDK 8
          // can launch by class name; a non-zero exit aborts before the main
          // process and surfaces the compiler's real diagnostic.
          for (const step of plan.preLaunchSteps ?? []) {
            if (!isCurrent()) return null;
            const stepResolved = await dependencies.resolveRunLaunch({
              root,
              executable: step.executable,
              workingDirectory: plan.workingDirectory,
              javaHomePath: configuration.javaHomePath,
              mavenExecutablePath:
                configuration.mavenExecutablePath || mavenContext?.mavenExecutablePath || "",
              mavenJavaHomePath:
                configuration.mavenJavaHomePath || mavenContext?.javaHomePath || "",
              runtimeExecutablePaths: state.effectiveRuntimeExecutablePaths,
              environment: mergeLaunchEnvironment(configuration.env, plan),
            });
            if (!isCurrent()) return null;
            const stepArguments = withJavaPaths(step.arguments, step.classpath);
            // Echo the compiler command into the session panel first, mirroring
            // the main process's `$ …` line so the compile step is visible.
            appendSessionOutput(
              `$ ${stepResolved.executable.split(/[\\/]/).pop()} ${stepArguments.join(" ")}\n`,
            );
            const outcome = await dependencies.executePreLaunchStep({
              executable: stepResolved.executable,
              arguments: stepArguments,
              workingDirectory: stepResolved.workingDirectory,
              environment: stepResolved.environment,
            });
            if (!isCurrent()) return null;
            if (outcome.output) appendSessionOutput(outcome.output);
            if (outcome.exitCode !== 0) {
              markPreLaunchFailure(outcome.exitCode);
              return null;
            }
          }
          await dependencies.startRunProcess({
            sessionId,
            executionId,
            executable: resolved.executable,
            arguments: mainArguments,
            workingDirectory: resolved.workingDirectory,
            environment: resolved.environment,
          });
          if (!isCurrent()) {
            await dependencies.stopRunProcess(sessionId, executionId);
            return null;
          }
          return { sessionId, executionId };
        } catch (error) {
          if (!isCurrent()) return null;
          const message = launchFailureMessage(error);
          // The reason used to be dropped whenever it was not an Error, which
          // is every failure the Tauri host reports, so neither the panel nor
          // the log said why a launch was refused.
          frontendTrace("error", "run.launch", "launchFailed", {
            configurationId: configuration.id,
            provider: configuration.provider,
            sessionId,
            reason: message,
          });
          if (sessionId === PRIMARY_SESSION_ID) {
            set({
              primaryRunning: false,
              primaryExitCode: 1,
              primaryOutput: trimOutput(`${get().primaryOutput}${message}\n`),
            });
          } else {
            set((current) => {
              const existingSession = current.sessions.find(
                (session) => session.id === sessionId,
              );
              const failedSession: RunSession = {
                id: sessionId,
                configurationId: configuration.id,
                title: configuration.name,
                output: trimOutput(`${existingSession?.output ?? ""}${message}\n`),
                isRunning: false,
                exitCode: 1,
              };
              return {
                selectedSessionId: sessionId,
                sessions: existingSession
                  ? current.sessions.map((session) =>
                      session.id === sessionId ? failedSession : session,
                    )
                  : [...current.sessions, failedSession],
              };
            });
          }
          return null;
        }
      },

      continueJavaLaunch: (sessionId, decisionId, remember) => {
        const pending = pendingJavaLaunchDecisions.get(sessionId);
        const decision = get().javaLaunchDecisions[sessionId];
        if (
          !pending ||
          !decision ||
          pending.decisionId !== decision.decisionId ||
          decisionId !== decision.decisionId
        )
          return;
        const root = get().root;
        if (remember && root) {
          setBuildFailurePolicy(root, "alwaysProceed");
        }
        pendingJavaLaunchDecisions.delete(sessionId);
        set((current) => {
          const javaLaunchDecisions = { ...current.javaLaunchDecisions };
          delete javaLaunchDecisions[sessionId];
          return { javaLaunchDecisions };
        });
        pending.resolve(true);
      },

      cancelJavaLaunch: (sessionId, decisionId) => {
        const pending = pendingJavaLaunchDecisions.get(sessionId);
        if (!pending || (decisionId !== undefined && pending.decisionId !== decisionId)) return;
        pendingJavaLaunchDecisions.delete(sessionId);
        set((current) => {
          const javaLaunchDecisions = { ...current.javaLaunchDecisions };
          delete javaLaunchDecisions[sessionId];
          return { javaLaunchDecisions };
        });
        pending.resolve(false);
      },

      rebuildJavaIndex: async (sessionId, decisionId) => {
        const pending = pendingJavaLaunchDecisions.get(sessionId);
        if (!pending || pending.decisionId !== decisionId) return;
        get().actions.cancelJavaLaunch(sessionId, decisionId);
        const root = get().root;
        if (!root) return;
        let message: string;
        try {
          await rebuildJavaIndex(root);
          message =
            "Java index cleared. Run the configuration again after project import finishes.\n";
        } catch (error) {
          message = `Failed to rebuild the Java index: ${launchFailureMessage(error)}\n`;
        }
        if (sessionId === PRIMARY_SESSION_ID) {
          set((current) => ({
            primaryOutput: trimOutput(`${current.primaryOutput}${message}`),
          }));
        } else {
          set((current) => ({
            sessions: current.sessions.map((session) =>
              session.id === sessionId
                ? { ...session, output: trimOutput(`${session.output}${message}`) }
                : session,
            ),
          }));
        }
      },

      stop: async (sessionId, executionId) => {
        const target = sessionId ?? get().selectedSessionId ?? PRIMARY_SESSION_ID;
        get().actions.cancelJavaLaunch(target);
        const ownedExecution = executions.get(target);
        const ownsSlot = !executionId || executionId === ownedExecution;
        if (ownsSlot) executions.delete(target);
        // Native ownership remains authoritative after a workspace store is disposed/recreated.
        await dependencies.stopRunProcess(target, executionId ?? ownedExecution).catch(() => undefined);
        // A new launch can claim the slot while the native stop is in flight.
        if (!ownsSlot || executions.has(target)) return;
        if (target === PRIMARY_SESSION_ID) {
          set({
            primaryRunning: false,
            primaryOutput: flushStampedOutput(target, get().primaryOutput),
          });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === target
              ? {
                  ...session,
                  isRunning: false,
                  output: flushStampedOutput(target, session.output),
                }
              : session,
          ),
        }));
      },

      clearOutput: (sessionId) => {
        const target = sessionId ?? get().selectedSessionId;
        if (!target || target === PRIMARY_SESSION_ID) {
          resetOutputStamper(PRIMARY_SESSION_ID);
          set({ primaryOutput: "", primaryExitCode: null });
          return;
        }
        resetOutputStamper(target);
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === target ? { ...session, output: "", exitCode: null } : session,
          ),
        }));
      },

      saveEditorChanges: async (configuration, options, toolchain, scope) => {
        const root = get().root;
        if (!root) {
          set({ saveError: editorSaveFailureMessage("prepare", "Open a project before saving.") });
          return false;
        }
        const result = await runEditorSaveWorkflow({
          prepare: () =>
            saveRunConfigurationEditorChanges(root, configuration.id, scope, options, toolchain),
          write: (mutation) => {
            const documents = [
              { relativePath: "run/local.json", contents: mutation.localDocument },
            ];
            if (mutation.projectDocument !== null) {
              documents.push({
                relativePath: "run/configurations.json",
                contents: mutation.projectDocument,
              });
            }
            if (mutation.toolchainDocument !== null) {
              documents.push({
                relativePath: "toolchains/local.json",
                contents: mutation.toolchainDocument,
              });
            }
            return writeRunDocuments(root, documents);
          },
          reload: async () => {
            const snapshot = await readRunProjectSnapshot(root, workspaceId, dependencies);
            if (snapshot.status === "missing") {
              throw new Error(
                snapshot.diagnostics[0]?.message ?? "Run configuration is not ready.",
              );
            }
            return snapshot;
          },
        });
        if (!result.ok) {
          set({ saveError: editorSaveFailureMessage(result.stage, result.error) });
          return false;
        }
        set({
          ...readyRunState(result.reloaded, configuration.id),
          saveError: null,
        });
        return true;
      },

      writeStdin: async (sessionId, input) => {
        try {
          await writeRunStdin(sessionId, input);
        } catch (error) {
          const message =
            error instanceof Error ? error.message : "Could not write to process input.";
          get().actions.appendOutput(sessionId, `${message}\n`);
        }
      },

      appendOutput: (sessionId, chunk) => {
        if (sessionId === PRIMARY_SESSION_ID) {
          set({ primaryOutput: appendStampedOutput(sessionId, get().primaryOutput, chunk) });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === sessionId
              ? { ...session, output: appendStampedOutput(sessionId, session.output, chunk) }
              : session,
          ),
        }));
      },

      finishProcess: (sessionId, exitCode) => {
        if (sessionId === PRIMARY_SESSION_ID) {
          set({
            primaryRunning: false,
            primaryExitCode: exitCode,
            primaryOutput: flushStampedOutput(sessionId, get().primaryOutput),
          });
          return;
        }
        set((current) => ({
          sessions: current.sessions.map((session) =>
            session.id === sessionId
              ? {
                  ...session,
                  isRunning: false,
                  exitCode,
                  output: flushStampedOutput(sessionId, session.output),
                }
              : session,
          ),
        }));
      },
    },
  }));
};

export const useRunStore = createWorkspaceScopedStore("run", createRunStore);

export function bindRunSessionWorkspace(sessionId: string, workspaceId?: string): void {
  sessionWorkspaces.set(sessionId, workspaceId ?? workspaceRuntimeRegistry.getActiveWorkspaceId());
}

export function runStoreForSession(sessionId: string) {
  const workspaceId = sessionWorkspaces.get(sessionId);
  return workspaceId ? useRunStore.getStore(workspaceId) : useRunStore;
}

export function releaseRunSessionWorkspace(sessionId: string): void {
  sessionWorkspaces.delete(sessionId);
  outputStampers.delete(sessionId);
}

export function runOptionsFor(configuration: RunConfiguration): RunOptions {
  return optionsFromConfiguration(configuration);
}

export { EMPTY_RUN_OPTIONS };
