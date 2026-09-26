import { saveWorkspaceBeforeLaunch } from "@/features/editor/services/save-workspace-before-launch";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { resolveRunLaunch, startRunProcess, stopRunProcess } from "@/features/run/api/run-host-api";
import {
  bindRunSessionWorkspace,
  releaseRunSessionWorkspace,
  useRunStore,
} from "@/features/run/stores/run.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import type { RunActionItem } from "@/features/run-actions/types/run-action.types";
import { phpProcessOwner } from "./process-owner";

export function isPhpSupportEnabled(): boolean {
  const extension = extensionRegistry.getExtension("lithe.php");
  return extension?.isEnabled === true && extension.state !== "not-installed";
}

export async function runPhpAction(
  action: RunActionItem,
  workspaceId: string,
  root: string,
): Promise<void> {
  if (!isPhpSupportEnabled() || !action.pluginCommand)
    throw new Error("Enable PHP Support before running PHP actions.");
  const id = `php:${crypto.randomUUID()}`;
  const command = action.pluginCommand;
  const store = useRunStore.getStore(workspaceId);
  await phpProcessOwner.start(
    id,
    workspaceId,
    async () => {
      await ensureRunProcessListeners();
      await saveWorkspaceBeforeLaunch(workspaceId);
      const resolved = await resolveRunLaunch({
        root,
        executable: { command: command.executable },
        workingDirectory: ".",
      });
      if (!isPhpSupportEnabled()) return;
      bindRunSessionWorkspace(id, workspaceId);
      store.setState((state) => ({
        sessions: [
          ...state.sessions,
          {
            id,
            configurationId: id,
            title: action.name,
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
          arguments: command.arguments,
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
