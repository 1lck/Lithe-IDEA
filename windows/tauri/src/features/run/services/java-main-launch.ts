import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { ensureRunProcessListeners } from "../hooks/use-run-process-events";
import { useRunStore } from "../stores/run.store";
import type { RunConfiguration } from "../types/run.types";
import { workspaceRelativePath } from "../utils/run-configuration";

/**
 * The configuration that launches `mainClass` from `sourcePath`.
 *
 * Generated entries come from JDT's workspace entry points, so every main
 * marker has one once discovery finished. A user-edited project or local
 * copy of the same entry wins, and the selected configuration wins among
 * equals, matching IDEA's reuse of an existing context configuration.
 */
export function javaMainConfiguration(
  configurations: readonly RunConfiguration[],
  selectedConfigurationId: string | null,
  sourcePath: string,
  mainClass: string,
): RunConfiguration | null {
  const matches = configurations.filter(
    (configuration) =>
      !configuration.disabled &&
      configuration.mainClass === mainClass &&
      configuration.sourcePath === sourcePath,
  );
  const rank = (configuration: RunConfiguration) =>
    (configuration.id === selectedConfigurationId ? 0 : 2) +
    (configuration.source === "generated" ? 1 : 0);
  return [...matches].sort((left, right) => rank(left) - rank(right))[0] ?? null;
}

export class JavaMainLaunchError extends Error {
  constructor(
    readonly reason: "noWorkspace" | "noConfiguration",
    message: string,
  ) {
    super(message);
  }
}

/** Resolves the configuration for a main marker, generating entries once when missing. */
async function resolveMainConfiguration(
  workspaceId: string,
  filePath: string,
  mainClass: string,
): Promise<RunConfiguration> {
  const store = useRunStore.getStore(workspaceId);
  const root =
    store.getState().root ?? useFileSystemStore.getStore(workspaceId).getState().rootFolderPath;
  const sourcePath = root ? workspaceRelativePath(root, filePath) : undefined;
  if (!root || !sourcePath) {
    throw new JavaMainLaunchError("noWorkspace", "Open the workspace that contains this file.");
  }
  if (store.getState().root !== root) await store.getState().actions.loadProject(root);
  const find = () => {
    const state = store.getState();
    return javaMainConfiguration(
      state.configurations,
      state.selectedConfigurationId,
      sourcePath,
      mainClass,
    );
  };
  const existing = find();
  if (existing) return existing;
  // The marker proves JDT can launch the class; the configuration list may
  // predate that answer, so it is regenerated once from current entry points.
  await store.getState().actions.generate(root);
  const generated = find();
  if (generated) return generated;
  throw new JavaMainLaunchError(
    "noConfiguration",
    `No run configuration exists for ${mainClass} yet. Wait for the Java project to finish importing, then try again.`,
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
