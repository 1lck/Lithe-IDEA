import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { BuildWorkspaceOwner } from "@/features/build/services/build-workspace-owner";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { createWindowsBuildProviderWorkspace, detectWindowsBuildProjects } from "./build-provider-platform";
import { scheduleFileWatcherRefresh, cancelFileWatcherRefreshes } from "@/features/file-system/services/file-watcher-refresh-scheduler";

export const windowsBuildWorkspaces = new BuildWorkspaceOwner((path, workspaceID) => {
  const schedulerID = `build:${crypto.randomUUID()}`;
  return new BuildWorkspaceController(path, {
    domain: createWindowsBuildProviderWorkspace(path), detect: detectWindowsBuildProjects, guard: pluginPlanGuard,
    runTarget: async (choice, assertCurrent, signal) => {
      const { useRunStore } = await import("@/features/run/stores/run.store");
      const { useUIState } = await import("@/features/window/stores/ui-state.store");
      assertCurrent();
      const state = useUIState.getState(); state.setBottomPaneActiveTab("run"); state.setIsBottomPaneVisible(true);
      await useRunStore.getStore(workspaceID).getState().actions.runBuildTarget(path, choice.reference, choice.title, assertCurrent, signal);
    },
    scheduleRefresh: refresh => {
      scheduleFileWatcherRefresh(schedulerID, "catalog", refresh);
      return () => cancelFileWatcherRefreshes(schedulerID);
    },
  });
});
