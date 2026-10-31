import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { BuildWorkspaceOwner } from "@/features/build/services/build-workspace-owner";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { createWindowsBuildProviderWorkspace, detectWindowsBuildProjects } from "./build-provider-platform";
import { scheduleFileWatcherRefresh, cancelFileWatcherRefreshes } from "@/features/file-system/services/file-watcher-refresh-scheduler";

export const windowsBuildWorkspaces = new BuildWorkspaceOwner(path => {
  const schedulerID = `build:${crypto.randomUUID()}`;
  return new BuildWorkspaceController(path, {
    domain: createWindowsBuildProviderWorkspace(path), detect: detectWindowsBuildProjects, guard: pluginPlanGuard,
    scheduleRefresh: refresh => {
      scheduleFileWatcherRefresh(schedulerID, "catalog", refresh);
      return () => cancelFileWatcherRefreshes(schedulerID);
    },
  });
});
