import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { getJavaWorkspaceLanguageServerOwner } from "@/features/editor/lsp/java-workspace-language-server";
import { readDocumentFile } from "@/platform/document-files";
import type { JavaMainMethods } from "@/platform/lsp-core-adapter";
import { discoverJavaRunSources } from "./java-run-markers";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { ensureRunProcessListeners } from "../hooks/use-run-process-events";
import { useRunStore } from "../stores/run.store";
import type { RunConfiguration } from "../types/run.types";
import { workspaceRelativePath } from "../utils/run-configuration";
import { selectContextConfiguration } from "../api/run-core-api";

/**
 * The configuration that launches `mainClass` from `sourcePath`.
 *
 * Generated entries come from JDT's workspace search or an explicitly
 * requested per-file JDT result for unmanaged sources. A user-edited project or local
 * copy of the same entry wins, and the selected configuration wins among
 * equals, matching IDEA's reuse of an existing context configuration.
 */
export async function javaMainConfiguration(
  configurations: readonly RunConfiguration[],
  selectedConfigurationId: string | null,
  sourcePath: string,
  mainClass: string,
  select = selectContextConfiguration,
): Promise<RunConfiguration | null> {
  const id = await select({
    sourcePath,
    symbol: mainClass,
    preferredId: selectedConfigurationId,
    caseInsensitivePaths: true,
    candidates: configurations.map((configuration) => ({
      id: configuration.id,
      sourcePath: configuration.sourcePath,
      symbol: configuration.mainClass,
      generated: configuration.source === "generated",
      disabled: configuration.disabled,
    })),
  });
  return configurations.find((configuration) => configuration.id === id) ?? null;
}

export class JavaMainLaunchError extends Error {
  constructor(
    readonly reason: "noWorkspace" | "noConfiguration" | "languageService" | "staleMarker",
    message: string,
  ) {
    super(message);
  }
}

/** Resolves the configuration for a main marker, generating entries once when missing. */
export async function resolveMainConfiguration(
  workspaceId: string,
  filePath: string,
  mainClass: string,
  dependencies = {
    runStore: useRunStore.getStore,
    fileStore: useFileSystemStore.getStore,
    save: saveWorkspaceBeforeLaunch,
    prepare: (workspaceId: string, root: string, filePath: string) =>
      getJavaWorkspaceLanguageServerOwner().prewarm({ workspaceId, root }, filePath),
    mainMethods: async (
      workspaceId: string,
      root: string,
      filePath: string,
    ): Promise<JavaMainMethods> => {
      const content = await readDocumentFile(filePath);
      if (content === null) throw new Error("The Java source no longer exists.");
      const sources = await discoverJavaRunSources({ workspaceId, root }, filePath, content, false);
      return { schemaVersion: 1, methods: sources.mainMethods, diagnostics: [] };
    },
    selectConfiguration: selectContextConfiguration,
  },
): Promise<RunConfiguration> {
  const store = dependencies.runStore(workspaceId);
  const root =
    store.getState().root ?? dependencies.fileStore(workspaceId).getState().rootFolderPath;
  const sourcePath = root ? workspaceRelativePath(root, filePath) : undefined;
  if (!root || !sourcePath) {
    throw new JavaMainLaunchError("noWorkspace", "Open the workspace that contains this file.");
  }
  if (store.getState().root !== root) await store.getState().actions.loadProject(root);
  const find = async () => {
    const state = store.getState();
    const selected = await javaMainConfiguration(
      state.configurations,
      state.selectedConfigurationId,
      sourcePath,
      mainClass,
      dependencies.selectConfiguration,
    );
    if (
      store.getState().configurations !== state.configurations ||
      store.getState().selectedConfigurationId !== state.selectedConfigurationId
    ) {
      throw new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("run.invalidTitle"));
    }
    return selected;
  };
  const existing = await find();
  if (store.getState().root !== root) {
    throw new JavaMainLaunchError("noWorkspace", "The workspace changed while preparing this run.");
  }
  if (existing) return existing;
  // Save before asking JDT again: an editor marker may describe unsaved code.
  await dependencies.save(workspaceId);
  const preparation = await dependencies.prepare(workspaceId, root, filePath);
  if (preparation.kind !== "ready") {
    throw new JavaMainLaunchError(
      "languageService",
      `The Java language service could not prepare this file (${preparation.kind}). Check Language Services and retry.`,
    );
  }
  const methods = await dependencies.mainMethods(workspaceId, root, filePath);
  const method = methods.methods.find((candidate) => candidate.mainClass === mainClass);
  if (!method) {
    throw new JavaMainLaunchError(
      "staleMarker",
      `JDT no longer reports ${mainClass} as runnable. Check the saved source and its Java diagnostics.`,
    );
  }
  if (store.getState().root !== root) {
    throw new JavaMainLaunchError("noWorkspace", "The workspace changed while preparing this run.");
  }
  // Workspace-wide resolveMainClass omits some unmanaged/default-project files.
  // Reuse the exact per-file JDT result, not a guessed or regex-detected main.
  await store.getState().actions.generate(root, {
    sourcePath,
    mainClass: method.mainClass,
    projectName: method.projectName,
  });
  if (store.getState().root !== root) {
    throw new JavaMainLaunchError(
      "noWorkspace",
      "The workspace changed while generating this run.",
    );
  }
  const generated = await find();
  if (store.getState().root !== root) {
    throw new JavaMainLaunchError("noWorkspace", "The workspace changed while generating this run.");
  }
  if (generated) return generated;
  throw new JavaMainLaunchError(
    "noConfiguration",
    store.getState().invalidMessage ??
      store.getState().javaDiscoveryMessage ??
      `Could not generate a run configuration for ${mainClass}. Check the Run panel diagnostics.`,
  );
}

function showRunPane(): void {
  const state = useUIState.getState();
  state.setBottomPaneActiveTab("run");
  state.setIsBottomPaneVisible(true);
}

/** Runs a main marker through the same configuration the Run pane would use. */
export async function runJavaMainFromEditor(
  workspaceId: string,
  filePath: string,
  mainClass: string,
): Promise<void> {
  const configuration = await resolveMainConfiguration(workspaceId, filePath, mainClass);
  const store = useRunStore.getStore(workspaceId);
  store.getState().actions.selectConfiguration(configuration.id);
  showRunPane();
  await ensureRunProcessListeners();
  // A refused launch (missing toolchain, pending build decision) explains
  // itself in the Run pane, which is already visible.
  await store.getState().actions.runConfiguration(configuration.id);
}

/** Opens the editor of the configuration a main marker would run. */
export async function editJavaMainConfiguration(
  workspaceId: string,
  filePath: string,
  mainClass: string,
  dependencies = {
    resolve: resolveMainConfiguration,
    edit: (workspace: string, id: string) =>
      useRunStore.getStore(workspace).getState().actions.editConfiguration(id),
    openSettings: () => useUIState.getState().openSettingsDialog("run"),
  },
): Promise<void> {
  const configuration = await dependencies.resolve(workspaceId, filePath, mainClass);
  dependencies.edit(workspaceId, configuration.id);
  dependencies.openSettings();
}
