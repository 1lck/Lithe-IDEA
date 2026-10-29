import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useBuildSystemsStore } from "@/features/build-systems/build-systems-store";
import {
  loadBuildModel,
  cancelBuildModel,
  BuildModelCancellationError,
  type ApproveBuildModel,
} from "@/features/build-systems/build-systems-service";
import type { BuildModelReview, BuildView } from "@/features/build-systems/build-systems-types";
import { pluginPlanGuard } from "./declarative-plugin-lifecycle";
import type { PluginReloadReceipt } from "./declarative-plugin-reload";

// Retain only the retry address; the ordinary model service remains the owner
// of native cancellation and shared-language cleanup after a failed stop.
const cleanupRetries = new Map<string, string>();

/** Project reloads share the real model service, consent and cleanup owners.
 * No lifecycle broadcast can disable the same package in another window. */
export async function reloadProjectSettings(
  receipt: PluginReloadReceipt,
  approve?: ApproveBuildModel,
  signal?: AbortSignal,
  modelPhase?: () => void,
) {
  if (signal?.aborted) throw new Error("plugin.settings.reloadCancelled");
  const retryKey = JSON.stringify([receipt.pluginId, receipt.workspacePath, receipt.project]);
  const cleanup = cleanupRetries.get(retryKey);
  if (cleanup) {
    await cancelBuildModel(cleanup);
    cleanupRetries.delete(retryKey);
  }
  const project = receipt.project;
  const runtime = project && workspaceRuntimeRegistry.getWorkspace(project.workspaceId);
  const guard = pluginPlanGuard();
  const assertCurrent = () => {
    if (signal?.aborted) throw new Error("plugin.settings.reloadCancelled");
    guard(receipt.pluginId);
    if (
      !project ||
      !runtime ||
      workspaceRuntimeRegistry.getActiveWorkspaceId() !== project.workspaceId ||
      workspaceRuntimeRegistry.getWorkspace(project.workspaceId) !== runtime ||
      runtime.descriptor.path !== receipt.workspacePath ||
      runtime.status !== "ready"
    )
      throw new Error("plugin.settings.staleContext");
  };
  assertCurrent();
  const store = useBuildSystemsStore.getStore(project!.workspaceId);
  const request = store.getState().actions.beginRequest();
  try {
    const { view } = await invoke<{ view: BuildView }>("declarative_plugins_reload_settings", {
      ...receipt,
      scope: "project",
    });
    assertCurrent();
    if (view.workspaceRoot !== receipt.workspacePath)
      throw new Error("plugin.settings.staleContext");
    // Native drain/detection is bounded and cannot be cancelled by the UI.
    // Model preparation, consent and execution use the ordinary cancel owner.
    modelPhase?.();
    assertCurrent();
    store.getState().actions.applyView(view, request);
    for (const instance of view.instances) {
      if (
        instance.pluginID !== receipt.pluginId ||
        !["command", "provider"].includes(instance.modelSource ?? "")
      )
        continue;
      assertCurrent();
      let prepared: string | null = null;
      let result;
      try {
        result = await loadBuildModel(
          receipt.pluginId,
          instance.buildSystemID,
          instance.root,
          approve ?? (async () => false),
          {},
          {
            signal,
            onPrepared: (review) => {
              prepared = review.operationId;
            },
            native: {
              prepare: (args) => {
                assertCurrent();
                return invoke<BuildModelReview>(
                  "declarative_plugins_prepare_settings_reload_model",
                  {
                    receipt,
                    buildSystemId: args.buildSystemId,
                    root: args.root,
                    runtimeExecutables: args.runtimeExecutables,
                  },
                );
              },
              load: (operationId) =>
                invoke("declarative_plugins_build_load_model", { operationId }),
              cancel: (operationId) =>
                invoke("declarative_plugins_build_cancel_operation", { operationId }),
            },
          },
        );
      } catch (error) {
        if (error instanceof BuildModelCancellationError && prepared)
          cleanupRetries.set(retryKey, prepared);
        throw error;
      }
      assertCurrent();
      if (!result) throw new Error("plugin.settings.reloadCancelled");
    }
  } finally {
    store.getState().actions.cancelRequest(request);
  }
}
