import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { BuildWorkspaceOwner } from "@/features/build/services/build-workspace-owner";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { createWindowsBuildProviderWorkspace, detectWindowsBuildProjects, saveWindowsBuildOption, resolveWindowsBuildOptions } from "./build-provider-platform";
import { scheduleFileWatcherRefresh, cancelFileWatcherRefreshes } from "@/features/file-system/services/file-watcher-refresh-scheduler";

export const windowsBuildWorkspaces = new BuildWorkspaceOwner((path, workspaceID) => {
  const schedulerID = `build:${crypto.randomUUID()}`;
  return new BuildWorkspaceController(path, {
    domain: createWindowsBuildProviderWorkspace(path), detect: detectWindowsBuildProjects, guard: pluginPlanGuard,
    options: {
      resolve: (manifest,entry,modelValues) => resolveWindowsBuildOptions(path,manifest,entry,modelValues),
      save: (entry,id,value,revision,modelValues,signal) => saveWindowsBuildOption(path,entry,id,value,revision,modelValues,signal),
    },
    runTarget: async (choice, assertCurrent, signal, debug) => {
      const { useRunStore } = await import("@/features/run/stores/run.store");
      const { useUIState } = await import("@/features/window/stores/ui-state.store");
      assertCurrent();
      const state = useUIState.getState(); state.setBottomPaneActiveTab("run"); state.setIsBottomPaneVisible(true);
      const actions = useRunStore.getStore(workspaceID).getState().actions;
      if (debug) {
        if (!choice.debugConfigurationType) throw new DOMException("Aborted", "AbortError");
        const { startWindowsBuildProviderDebug } = await import("./build-provider-debug");
        assertCurrent();
        await startWindowsBuildProviderDebug({ workspaceId:workspaceID, root:path, name:choice.title,
          configurationType:choice.debugConfigurationType, assertCurrent, signal,
          startRun:(options,current,preparationSignal) => actions.runBuildTarget(path,choice.reference,choice.title,assertCurrent,preparationSignal,{options,assertCurrent:current}),
          stopRun:instance => actions.stop(instance.sessionId,instance.executionId),
        });
      } else await actions.runBuildTarget(path, choice.reference, choice.title, assertCurrent, signal);
    },
    scheduleRefresh: refresh => {
      scheduleFileWatcherRefresh(schedulerID, "catalog", refresh);
      return () => cancelFileWatcherRefreshes(schedulerID);
    },
  });
});
