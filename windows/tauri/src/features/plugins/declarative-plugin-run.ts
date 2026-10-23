import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import {
  bindRunSessionWorkspace,
  releaseRunSessionWorkspace,
  useRunStore,
} from "@/features/run/stores/run.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import type { RunActionItem } from "@/features/run-actions/types/run-action.types";
import {
  invokeDeclarativePluginOwner,
  listDeclarativePlugins,
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

/** The declarative run action for the file's owner, or null. */
export async function declarativeRunActionForFile(
  filePath: string,
): Promise<RunActionItem | null> {
  const owner = await invokeDeclarativePluginOwner(filePath);
  if (!owner) return null;
  // A plugin whose manifest declares a test template also gets a test action
  // routed through the same run pipeline with the file scope.
  const hasTests = (await listDeclarativePlugins()).some(
    (plugin) =>
      plugin.pluginId === owner.pluginId &&
      plugin.status === "accepted" &&
      plugin.enabled &&
      plugin.declaresTests,
  );
  return {
    id: `declarative:${owner.pluginId}:${owner.languageId}`,
    name: owner.displayName,
    description: owner.languageId,
    source: "declarative",
    sourceLabel: owner.displayName,
    declarativeOwner: { pluginId: owner.pluginId, languageId: owner.languageId },
    declarativeTest: hasTests,
  };
}

export async function runDeclarativeAction(
  action: RunActionItem,
  workspaceId: string,
  root: string,
  filePath: string,
): Promise<void> {
  const owner = action.declarativeOwner;
  if (!owner) throw new Error("The action does not name a declarative plugin.");
  // The plan chosen depends on the action kind: run plans take the file,
  // test plans (when the action carries declarativeTest) reuse the run
  // entry with the file's test template when the plugin declares one.
  const relative = toWorkspaceRelative(filePath, root);
  const plan = action.declarativeTest
    ? // Test-plan project markers are answered from the workspace file list
      // the host frontend can supply; v1 passes the opened file so marker
      // detection at minimum sees the active project file. Full workspace
      // scanning lands with the test-panel integration.
      await resolveDeclarativeTestPlan(
        owner.pluginId,
        owner.languageId,
        [relative],
      ).catch(() => resolveDeclarativeRunPlan(owner.pluginId, owner.languageId, relative))
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
