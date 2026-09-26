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
import { extensionProcessOwner } from "./extension-process-owner";

export function isExtensionRunEnabled(extensionId: string): boolean {
  const extension = extensionRegistry.getExtension(extensionId);
  return extension?.isEnabled === true && extension.state !== "not-installed";
}

export async function runExtensionAction(
  action: RunActionItem,
  workspaceId: string,
  root: string,
): Promise<void> {
  const extensionId = action.extensionId;
  if (!extensionId || !isExtensionRunEnabled(extensionId) || !action.pluginCommand)
    throw new Error("Enable the owning extension before running this action.");
  const manifest = extensionRegistry.getExtension(extensionId)!.manifest;
  if (!manifest.runActions?.executables.includes(action.pluginCommand.executable))
    throw new Error("The extension has not declared this executable.");
  const id = `extension:${extensionId}:${crypto.randomUUID()}`;
  const command = action.pluginCommand;
  const store = useRunStore.getStore(workspaceId);
  await extensionProcessOwner.start(
    id,
    workspaceId,
    extensionId,
    async () => {
      await ensureRunProcessListeners();
      await saveWorkspaceBeforeLaunch(workspaceId);
      const resolved = await resolveRunLaunch({
        root,
        executable: { command: command.executable },
        workingDirectory: ".",
      });
      if (!isExtensionRunEnabled(extensionId)) return;
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
