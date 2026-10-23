import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import {
  bindRunSessionWorkspace,
  releaseRunSessionWorkspace,
  useRunStore,
} from "@/features/run/stores/run.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import type { RunActionItem } from "@/features/run-actions/types/run-action.types";
import {
  invokeDeclarativePluginOwner,
  getDeclarativePluginManifest,
  resolveDeclarativeRunPlan,
  resolveDeclarativeTestPlan,
  type DeclarativeRunPlan,
} from "./declarative-plugin-launch";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";

/**
 * Run actions for contract v1 plugins, mirroring the Worker extension run
 * path: Core expands the declared template, the shared run pipeline resolves
 * and starts the process, and the process owner tracks it per workspace and
 * plugin so disabling or uninstalling stops its sessions. File ownership
 * comes from the host's live catalog (`declarative_plugins_language_owner`),
 * so there is no second catalog to drift.
 */

/** Run and test actions declared for the file's owning language. */
export async function declarativeRunActionsForFile(
  filePath: string,
): Promise<RunActionItem[]> {
  const owner = await invokeDeclarativePluginOwner(filePath);
  if (!owner) return [];
  const manifest = await getDeclarativePluginManifest(owner.pluginId);
  const providers = Array.isArray(manifest?.executionProviders)
    ? manifest.executionProviders as Array<Record<string, unknown>>
    : [];
  const provider = providers.find((item) => item.languageID === owner.languageId);
  if (!provider) return [];
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  return (["run", "test"] as const)
    .filter((kind) => provider[kind] != null)
    .map((kind) => ({
      id: `declarative:${owner.pluginId}:${owner.languageId}:${kind}`,
      name: `${t(`runActions.${kind}`)} ${owner.displayName}`,
      description: owner.languageId,
      source: "declarative" as const,
      sourceLabel: owner.displayName,
      declarativeOwner: { pluginId: owner.pluginId, languageId: owner.languageId },
      declarativeTest: kind === "test",
    }));
}

export async function runDeclarativeAction(
  action: RunActionItem,
  workspaceId: string,
  root: string,
  filePath: string,
): Promise<void> {
  const owner = action.declarativeOwner;
  if (!owner) throw new Error("The action does not name a declarative plugin.");
  const relative = toWorkspaceRelative(filePath, root);
  const plan = action.declarativeTest
    ? await resolveDeclarativeTestPlan(owner.pluginId, owner.languageId, root)
    : await resolveDeclarativeRunPlan(owner.pluginId, owner.languageId, relative);
  await startDeclarativePlan(plan, workspaceId, root, filePath);
}

async function startDeclarativePlan(
  plan: DeclarativeRunPlan,
  workspaceId: string,
  root: string,
  title: string,
): Promise<void> {
  const id = `declarative:${plan.pluginId}:${crypto.randomUUID()}`;
  const store = useRunStore.getStore(workspaceId);
  await declarativePluginProcessOwner.start(
    id,
    workspaceId,
    plan.pluginId,
    async () => {
      await ensureRunProcessListeners();
      await saveWorkspaceBeforeLaunch(workspaceId);
      const resolved = await resolveRunLaunch({
        root,
        executable: plan.executable,
        workingDirectory: plan.workingDirectory,
      });
      bindRunSessionWorkspace(id, workspaceId);
      store.setState((state) => ({
        sessions: [
          ...state.sessions,
          {
            id,
            configurationId: id,
            title: `${title} (declarative)`,
            output: "",
            isRunning: true,
            exitCode: null,
          },
        ],
        selectedSessionId: id,
      }));
      const ui = useUIState.getState();
      ui.setBottomPaneActiveTab("run");
      ui.setIsBottomPaneVisible(true);
      try {
        await startRunProcess({
          sessionId: id,
          executionId: id,
          ...resolved,
          arguments: plan.arguments,
        });
      } catch (error) {
        store.getState().actions.finishProcess(id, 1);
        releaseRunSessionWorkspace(id);
        throw error;
      }
    },
    async () => {
      await stopRunProcess(id, id);
      store.getState().actions.finishProcess(id, -1);
      releaseRunSessionWorkspace(id);
    },
  );
}

function toWorkspaceRelative(filePath: string, root: string): string {
  const normalized = filePath.replace(/\\/g, "/");
  const normalizedRoot = root.replace(/\\/g, "/").replace(/\/$/, "");
  if (normalized.toLowerCase().startsWith(`${normalizedRoot.toLowerCase()}/`)) {
    return normalized.slice(normalizedRoot.length + 1);
  }
  return normalized;
}
