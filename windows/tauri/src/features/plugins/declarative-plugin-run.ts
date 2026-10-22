import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import {
  bindRunSessionWorkspace,
  releaseRunSessionWorkspace,
  useRunStore,
} from "@/features/run/stores/run.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import {
  listDeclarativePlugins,
  resolveDeclarativeRunPlan,
  type DeclarativeRunPlan,
} from "./declarative-plugin-launch";
import { declarativePluginProcessOwner } from "./declarative-plugin-process-owner";

/**
 * Run actions for contract v1 plugins, mirroring the Worker extension run
 * path: Core expands the declared template, the shared run pipeline resolves
 * and starts the process, and the process owner tracks it per workspace and
 * plugin so disabling or uninstalling stops its sessions.
 */

export interface DeclarativeRunTarget {
  /** Run session ID, shaped `declarative:<pluginID>:<uuid>`. */
  id: string;
  title: string;
}

export function isDeclarativeRunEnabled(pluginId: string): boolean {
  return findAcceptedPlugin(pluginId)?.enabled === true;
}

function findAcceptedPlugin(pluginId: string) {
  // Synchronous accessors are not available on the cached Tauri state; the
  // frontend keeps the scanned catalog in this module after each rescan.
  return declarativeCatalog.find((plugin) => plugin.pluginId === pluginId);
}

let declarativeCatalog: Awaited<ReturnType<typeof listDeclarativePlugins>> = [];

/** Refreshes the cached catalog; call after rescans and installs. */
export function refreshDeclarativeCatalog(): void {
  void listDeclarativePlugins().then((plugins) => {
    declarativeCatalog = plugins;
  });
}

export function declarativePluginForFile(
  filePath: string,
): { pluginId: string; languageId: string } | null {
  const lower = filePath.toLowerCase();
  const dot = lower.lastIndexOf(".");
  const extension = dot === -1 ? "" : lower.slice(dot + 1);
  for (const plugin of declarativeCatalog) {
    if (plugin.status !== "accepted" || !plugin.enabled) continue;
    for (const language of plugin.languages) {
      if (language.fileExtensions.some((declared) => declared.toLowerCase() === extension)) {
        return { pluginId: plugin.pluginId, languageId: language.id };
      }
    }
  }
  return null;
}

export async function runDeclarativePluginFile(
  filePath: string,
  workspaceId: string,
  root: string,
  userArguments: string[] = [],
): Promise<void> {
  const owner = declarativePluginForFile(filePath);
  if (!owner) throw new Error("No enabled declarative plugin owns this file.");
  const relative = toWorkspaceRelative(filePath, root);
  const plan = await resolveDeclarativeRunPlan(
    owner.pluginId,
    owner.languageId,
    relative,
    userArguments,
  );
  await startDeclarativePlan(plan, workspaceId, root, relative);
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
      if (!isDeclarativeRunEnabled(plan.pluginId)) return;
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
