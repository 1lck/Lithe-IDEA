import { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { BuildWorkspaceOwner } from "@/features/build/services/build-workspace-owner";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { createWindowsBuildProviderWorkspace, detectWindowsBuildProjects } from "./build-provider-platform";

export const windowsBuildWorkspaces = new BuildWorkspaceOwner(path => new BuildWorkspaceController(path, {
  domain: createWindowsBuildProviderWorkspace(path), detect: detectWindowsBuildProjects, guard: pluginPlanGuard,
}));
