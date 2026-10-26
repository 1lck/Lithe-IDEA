import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import {
  useBuildSystemsStore,
  type BuildRequestVersion,
  type BuildSystemsState,
} from "@/features/build-systems/build-systems-store";
import type { BuildView } from "@/features/build-systems/build-systems-types";
import { pluginPlanGuard, subscribePluginActivity } from "./declarative-plugin-lifecycle";
import type { StoreApi } from "zustand";

export interface PluginWebBuildRequest {
  operationId: string;
  pluginId: string;
  pageLabel: string;
  pageGeneration: number;
  hostLabel: string;
  workspaceId: string;
  workspacePath: string;
  method: "build.instances" | "build.setOptions";
}

export interface PluginWebBuildWorkspace {
  id: string;
  path: string;
  store: StoreApi<BuildSystemsState>;
}

/** Native owns the request, deadline, build facts and writes. This port only
 * lets the owning workbench accept it and mirror the resulting native view. */
export interface PluginWebBuildPort {
  windowLabel(): string;
  workspace(): PluginWebBuildWorkspace | null;
  listen(handler: (request: PluginWebBuildRequest) => void): Promise<() => void>;
  handle(operationId: string, accept: boolean): Promise<BuildView | null>;
  complete(operationId: string): Promise<void>;
  optionsChanged?(workspace: PluginWebBuildWorkspace): Promise<void>;
  subscribeWorkspace(handler: () => void): () => void;
  subscribePlugin(handler: (pluginId: string) => void): () => void;
  pluginGuard(): (pluginId: string) => void;
  scheduleDeadline(handler: () => void): () => void;
  report(error: unknown): void;
}

const REQUEST_TIMEOUT_MS = 10_000;
const MAX_PENDING_REQUESTS = 128;

const nativePort: PluginWebBuildPort = {
  windowLabel: () => getCurrentWindow().label,
  workspace: () => {
    const runtime = workspaceRuntimeRegistry.getActiveWorkspace();
    const path = runtime?.descriptor.path;
    if (!runtime || runtime.status !== "ready" || !path) return null;
    return {
      id: runtime.descriptor.id,
      path,
      store: useBuildSystemsStore.getStore(runtime.descriptor.id),
    };
  },
  listen: (handler) =>
    listen<PluginWebBuildRequest>("plugin-web-build-request", ({ payload }) => handler(payload), {
      target: { kind: "Window", label: getCurrentWindow().label },
    }),
  handle: (operationId, accept) =>
    invoke("declarative_plugins_web_build_handle", {
      operationId,
      phase: accept ? "accept" : "reject",
    }),
  complete: (operationId) =>
    invoke("declarative_plugins_web_build_handle", { operationId, phase: "complete" }),
  optionsChanged: async (workspace) => {
    const { updateBuildLanguageImport } =
      await import("@/features/build-systems/build-language-import");
    await updateBuildLanguageImport({ workspaceId: workspace.id, root: workspace.path });
  },
  subscribeWorkspace: (handler) => workspaceRuntimeRegistry.subscribe(handler),
  subscribePlugin: subscribePluginActivity,
  pluginGuard: pluginPlanGuard,
  scheduleDeadline: (handler) => {
    const timer = setTimeout(handler, REQUEST_TIMEOUT_MS);
    return () => clearTimeout(timer);
  },
  report: (error) => console.warn("Plugin web build request failed", error),
};

interface PendingRequest {
  payload: PluginWebBuildRequest;
  workspace: PluginWebBuildWorkspace;
  version: BuildRequestVersion;
  guard: (pluginId: string) => void;
  stopDeadline: () => void;
  invalidated: boolean;
}

function validRequest(request: PluginWebBuildRequest): boolean {
  return (
    !!request &&
    [
      request.operationId,
      request.pluginId,
      request.pageLabel,
      request.hostLabel,
      request.workspaceId,
      request.workspacePath,
    ].every((value) => typeof value === "string" && !!value) &&
    Number.isSafeInteger(request.pageGeneration) &&
    request.pageGeneration > 0 &&
    (request.method === "build.instances" || request.method === "build.setOptions")
  );
}

export async function initializePluginWebBuildListener(
  port: PluginWebBuildPort = nativePort,
): Promise<() => void> {
  const hostLabel = port.windowLabel();
  const pending = new Map<string, PendingRequest>();
  let stopped = false;
  let unlisten: (() => void) | null = null;

  const refuse = (id: string) => {
    // Native can already have revoked or expired the request. The refusal
    // never accepts another page's operation, even when its id is stale.
    void port.handle(id, false).catch(port.report);
  };
  const current = (entry: PendingRequest) => {
    const workspace = port.workspace();
    try {
      entry.guard(entry.payload.pluginId);
    } catch {
      return false;
    }
    return (
      !stopped &&
      !entry.invalidated &&
      port.windowLabel() === hostLabel &&
      !!workspace &&
      workspace.id === entry.workspace.id &&
      workspace.path === entry.workspace.path &&
      workspace.store === entry.workspace.store
    );
  };
  const invalidate = (entry: PendingRequest) => {
    if (entry.invalidated) return;
    entry.invalidated = true;
    entry.stopDeadline();
    pending.delete(entry.payload.operationId);
    if (entry.payload.method === "build.setOptions")
      entry.workspace.store.getState().actions.cancelRequest(entry.version);
    refuse(entry.payload.operationId);
  };
  const checkWorkspace = () => {
    for (const entry of pending.values()) if (!current(entry)) invalidate(entry);
  };
  const releaseWorkspace = port.subscribeWorkspace(checkWorkspace);
  const releasePlugin = port.subscribePlugin((id) => {
    for (const entry of pending.values()) if (entry.payload.pluginId === id) invalidate(entry);
  });

  const receive = (payload: PluginWebBuildRequest) => {
    if (
      !validRequest(payload) ||
      payload.hostLabel !== hostLabel ||
      pending.has(payload.operationId)
    )
      return;
    const workspace = port.workspace();
    if (
      stopped ||
      !workspace ||
      workspace.id !== payload.workspaceId ||
      workspace.path !== payload.workspacePath ||
      pending.size >= MAX_PENDING_REQUESTS
    ) {
      refuse(payload.operationId);
      return;
    }
    const guard = port.pluginGuard();
    try {
      guard(payload.pluginId);
    } catch {
      refuse(payload.operationId);
      return;
    }
    const state = workspace.store.getState();
    const entry: PendingRequest = {
      payload,
      workspace,
      guard,
      stopDeadline: () => {},
      invalidated: false,
      version: { sequence: state.requestSequence, revocationEpoch: state.revocationEpoch },
    };
    pending.set(payload.operationId, entry);
    if (payload.method === "build.setOptions") entry.version = state.actions.beginRequest();
    entry.stopDeadline = port.scheduleDeadline(() => invalidate(entry));
    if (!current(entry)) {
      invalidate(entry);
      return;
    }
    void port
      .handle(payload.operationId, true)
      .then(async (view) => {
        if (!current(entry)) {
          invalidate(entry);
          return;
        }
        const latest = workspace.store.getState();
        if (
          (view && view.workspaceRoot !== workspace.path) ||
          latest.requestSequence !== entry.version.sequence ||
          latest.revocationEpoch !== entry.version.revocationEpoch
        ) {
          invalidate(entry);
          return;
        }
        // The native result is still held for this page. Re-check the host's
        // active workspace before authorizing its final, generation-checked delivery.
        await port.complete(payload.operationId);
        if (view && current(entry)) {
          const afterDelivery = workspace.store.getState();
          if (
            afterDelivery.requestSequence === entry.version.sequence &&
            afterDelivery.revocationEpoch === entry.version.revocationEpoch
          ) {
            afterDelivery.actions.applyView(view, entry.version);
            if (payload.method === "build.setOptions" && current(entry))
              await port.optionsChanged?.(workspace);
          }
        }
      })
      .catch((error: unknown) => {
        if (current(entry)) port.report(error);
        invalidate(entry);
      })
      .finally(() => {
        entry.stopDeadline();
        if (pending.get(payload.operationId) === entry) pending.delete(payload.operationId);
        if (payload.method === "build.setOptions")
          workspace.store.getState().actions.cancelRequest(entry.version);
      });
  };
  const cleanup = () => {
    if (stopped) return;
    stopped = true;
    for (const entry of pending.values()) invalidate(entry);
    unlisten?.();
    releaseWorkspace();
    releasePlugin();
    if (typeof window !== "undefined") window.removeEventListener("pagehide", cleanup);
  };
  try {
    if (typeof window !== "undefined") window.addEventListener("pagehide", cleanup, { once: true });
    const acquired = await port.listen(receive);
    if (stopped) acquired();
    else unlisten = acquired;
    return cleanup;
  } catch (error) {
    cleanup();
    throw error;
  }
}
