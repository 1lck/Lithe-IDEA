import { invoke } from "@/platform/tauri-core";
import { buildRunNative, type BuildRunNative } from "./build-run-native";
import type { BuildDependenciesResult, BuildDependenciesReview } from "./build-dependencies-types";

export interface BuildDependenciesNative extends Omit<BuildRunNative, "prepare" | "execute"> {
  prepare(
    workspaceRoot: string,
    pluginId: string,
    buildSystemId: string,
    root: string,
    selection: { projectId: string | null },
  ): Promise<BuildDependenciesReview>;
  execute(operationId: string): Promise<BuildDependenciesResult>;
}
export const buildDependenciesNative: BuildDependenciesNative = {
  ...buildRunNative,
  prepare: (workspaceRoot, pluginId, buildSystemId, root, selection) =>
    invoke("declarative_plugins_build_prepare_dependencies", {
      workspaceRoot,
      pluginId,
      buildSystemId,
      root,
      selection: { projectId: selection.projectId },
    }),
  execute: (operationId) => invoke("declarative_plugins_build_load_dependencies", { operationId }),
};
