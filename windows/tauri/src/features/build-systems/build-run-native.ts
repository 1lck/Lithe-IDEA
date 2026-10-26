import { getCurrentWindow } from "@tauri-apps/api/window";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@/platform/tauri-core";
import { syncInstance } from "./build-systems-service";
import type { BuildRunDefinition, BuildRunReview, BuildRunSelection } from "./build-run-types";
import type { BuildOutputEvent, BuildRunTerminal } from "./output/build-output-types";

export interface BuildRunNative {
  windowLabel(): string;
  definition(pluginId: string, buildSystemId: string): Promise<BuildRunDefinition>;
  save(workspaceId: string): Promise<void>;
  sync(pluginId: string, buildSystemId: string, root: string): Promise<void>;
  prepare(
    workspaceRoot: string,
    pluginId: string,
    buildSystemId: string,
    root: string,
    selection: BuildRunSelection,
  ): Promise<BuildRunReview>;
  execute(operationId: string): Promise<BuildRunTerminal>;
  /** Additional result identity checks run after the common owner retains the review ID. */
  validateReview?: (review: BuildRunReview, selection: BuildRunSelection) => void;
  cancel(operationId: string): Promise<void>;
  listen(windowLabel: string, sink: (event: BuildOutputEvent) => void): Promise<() => void>;
  /** Injected only for deterministic event-drain timeout tests. */
  scheduleOutputDrain?: (callback: () => void, milliseconds: number) => () => void;
}

export const buildRunNative: BuildRunNative = {
  windowLabel: () => getCurrentWindow().label,
  definition: async (pluginId, buildSystemId) => {
    const { getDeclarativePluginManifest, listDeclarativePlugins } =
      await import("@/features/plugins/declarative-plugin-launch");
    const { invokePluginDetailsService } =
      await import("@/features/plugins/details/plugin-details.service");
    const [manifest, plugins] = await Promise.all([
      getDeclarativePluginManifest(pluginId),
      listDeclarativePlugins(),
    ]);
    const plugin = plugins.find(
      (row) => row.pluginId === pluginId && row.enabled && row.status === "accepted",
    );
    const system = (
      manifest?.buildSystems as Array<BuildRunDefinition & { id: string }> | undefined
    )?.find((row) => row.id === buildSystemId);
    if (!plugin || !system) throw new Error("plugin.build.unavailable");
    const details = await invokePluginDetailsService.load({ pluginId, source: plugin.source });
    const programs = details.programs.filter((program) => {
      const value = program as { kind?: string; buildSystemID?: string } | null;
      return value?.kind === "buildSystem" && value.buildSystemID === buildSystemId;
    });
    if (!details.enabled || details.status !== "accepted" || !programs.length)
      throw new Error("plugin.build.unavailable");
    return {
      tasks: system.tasks ?? [],
      test: system.test,
      dependencies: system.dependencies,
      programs,
    };
  },
  save: async (workspaceId) =>
    (
      await import("@/features/editor/services/save-workspace-before-launch")
    ).saveWorkspaceBeforeLaunch(workspaceId),
  sync: syncInstance,
  prepare: (workspaceRoot, pluginId, buildSystemId, root, selection) =>
    invoke("declarative_plugins_build_prepare_run", {
      workspaceRoot,
      pluginId,
      buildSystemId,
      root,
      selection,
    }),
  execute: (operationId) => invoke("declarative_plugins_build_execute_run", { operationId }),
  cancel: (operationId) => invoke("declarative_plugins_build_cancel_operation", { operationId }),
  // Native's payload has no window field; the Tauri target is the window
  // identity boundary. Every payload additionally carries all six run keys.
  listen: (label, sink) =>
    listen<BuildOutputEvent>("declarative-build-output", ({ payload }) => sink(payload), {
      target: { kind: "Window", label },
    }),
};
