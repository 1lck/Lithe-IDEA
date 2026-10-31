import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { pluginPlanGuard, subscribePluginActivity } from "./declarative-plugin-lifecycle";
import {
  createWebFunctionApproval,
  type WebFunctionApproval,
  type WebFunctionReview,
} from "./plugin-web-function-approval";
import {
  functionFailure,
  type FunctionFailure,
  type FunctionContext,
  type FunctionSnapshot,
} from "./plugin-function-session";
import { beginWebFunctionCleanupRead } from "./plugin-functions";

export interface WebFunctionCleanupFailure {
  operationId: string;
  context: FunctionContext;
  error: FunctionFailure;
}

export interface WebFunctionRequest {
  operationId: string;
  pageLabel: string;
  pageGeneration: number;
  hostLabel: string;
  pluginId: string;
  workspaceId: string;
  workspacePath: string;
  instance: string;
  function?: string;
  params: unknown;
  call?: string;
  list: boolean;
}
export interface WebFunctionPort {
  windowLabel(): string;
  workspace(): { id: string; path: string } | null;
  guard(): (pluginId: string) => void;
  approval(): WebFunctionApproval;
  listen(handler: (request: WebFunctionRequest) => Promise<void>): Promise<() => void>;
  listenCancelled(handler: (operationId: string) => void): Promise<() => void>;
  listenCleanupFailed(
    handler: (failure: WebFunctionCleanupFailure) => Promise<void>,
  ): Promise<() => void>;
  readCleanup(
    context: FunctionContext,
  ): Promise<Pick<FunctionSnapshot, "context" | "phase" | "error"> | null>;
  prepare(request: WebFunctionRequest): Promise<WebFunctionReview>;
  confirm(operationId: string): Promise<void>;
  cancel(
    operationId: string,
    error?: FunctionFailure,
    expectedWindowIncarnation?: number,
  ): Promise<void>;
  subscribeWorkspace(handler: () => void): () => void;
  subscribePlugin(handler: (pluginId: string) => void): () => void;
  report(error: unknown): void;
}
interface Pending {
  request: WebFunctionRequest;
  controller: AbortController;
  approval: WebFunctionApproval;
  guard: (pluginId: string) => void;
  context?: FunctionContext;
}
const nativePort: WebFunctionPort = {
  windowLabel: () => getCurrentWindow().label,
  workspace: () => {
    const workspace = workspaceRuntimeRegistry.getActiveWorkspace();
    const descriptor = workspace?.status === "ready" ? workspace.descriptor : null;
    return descriptor?.path ? { id: descriptor.id, path: descriptor.path } : null;
  },
  guard: pluginPlanGuard,
  approval: createWebFunctionApproval,
  listen: (handler) =>
    listen<WebFunctionRequest>(
      "plugin-web-function-request",
      ({ payload }) => {
        void handler(payload);
      },
      {
        target: { kind: "Window", label: getCurrentWindow().label },
      },
    ),
  listenCancelled: (handler) =>
    listen<{ operationId: string }>(
      "plugin-web-function-cancelled",
      ({ payload }) => handler(payload.operationId),
      {
        target: { kind: "Window", label: getCurrentWindow().label },
      },
    ),
  listenCleanupFailed: (handler) =>
    listen<WebFunctionCleanupFailure>(
      "plugin-web-function-cleanup-failed",
      ({ payload }) => {
        void handler(payload);
      },
      { target: { kind: "Window", label: getCurrentWindow().label } },
    ),
  readCleanup: async (context) => {
    try {
      return await invoke("declarative_plugins_function_state", {
        operationId: context.operationId,
        cleanupOnly: true,
        expectedWindowIncarnation: context.windowIncarnation,
      });
    } catch (error) {
      if (functionFailure(error).code === "plugin.function.staleContext") return null;
      throw error;
    }
  },
  prepare: (request) =>
    invoke("declarative_plugins_web_function_prepare", {
      pageLabel: request.pageLabel,
      instance: request.instance,
      functionId: request.function ?? "",
      operationId: request.operationId,
      params: request.params,
      list: request.list,
    }),
  confirm: (operationId) => invoke("declarative_plugins_function_confirm", { operationId }),
  cancel: (operationId, webError, expectedWindowIncarnation) =>
    invoke("declarative_plugins_function_cancel", {
      operationId,
      webError,
      expectedWindowIncarnation,
    }),
  subscribeWorkspace: (handler) => workspaceRuntimeRegistry.subscribe(handler),
  subscribePlugin: subscribePluginActivity,
  report: (error) => console.warn("Plugin web function cleanup failed", error),
};
function valid(request: WebFunctionRequest): boolean {
  return (
    !!request &&
    [
      request.operationId,
      request.pageLabel,
      request.hostLabel,
      request.pluginId,
      request.workspaceId,
      request.workspacePath,
      request.instance,
    ].every((value) => typeof value === "string" && value.length > 0) &&
    Number.isSafeInteger(request.pageGeneration) &&
    request.pageGeneration > 0 &&
    typeof request.list === "boolean" &&
    (!request.function || (typeof request.function === "string" && request.function.length <= 128))
  );
}
const cancelled: FunctionFailure = { code: "requestCancelled", message: "requestCancelled" };
function validContext(context: FunctionContext, host: string, operationId: string): boolean {
  return (
    !!context &&
    context.window === host &&
    context.operationId === operationId &&
    Number.isSafeInteger(context.windowIncarnation) &&
    context.windowIncarnation > 0 &&
    [
      context.pluginId,
      context.workspacePath,
      context.packageIdentity,
      context.settingIdentity,
      context.actionId,
    ].every((value) => typeof value === "string" && value.length > 0) &&
    context.actionId.startsWith("__web__:") &&
    typeof context.functionId === "string" &&
    Number.isSafeInteger(context.generation)
  );
}
export async function initializePluginWebFunctionListener(
  port: WebFunctionPort = nativePort,
): Promise<() => void> {
  const hostLabel = port.windowLabel();
  const pending = new Map<string, Pending>();
  const cleanups: Array<() => void> = [];
  let stopped = false;
  const retainFailure = async (context: FunctionContext | undefined, error: unknown) => {
    if (!context || !validContext(context, hostLabel, context.operationId)) return;
    const read = beginWebFunctionCleanupRead(context);
    try {
      try {
        const snapshot = await port.readCleanup(context);
        if (
          !snapshot ||
          (Object.keys(context) as Array<keyof FunctionContext>).some(
            (key) => snapshot.context[key] !== context[key],
          )
        )
          return;
      } catch (readError) {
        port.report(readError);
      }
      read.retain(functionFailure(error), async () => {
        try {
          await port.cancel(context.operationId, undefined, context.windowIncarnation);
        } catch (failure) {
          if (functionFailure(failure).code !== "plugin.function.staleContext") throw failure;
          // Lifecycle cleanup may have released this exact receipt before Retry.
          if ((await port.readCleanup(context)) !== null) throw failure;
        }
      });
    } finally {
      read.release();
    }
  };
  const cancelNative = async (entry: Pending, error: FunctionFailure) => {
    try {
      await port.cancel(entry.request.operationId, error, entry.context?.windowIncarnation);
    } catch (failure) {
      await retainFailure(entry.context, failure);
      port.report(failure);
    }
  };
  const current = (entry: Pending) => {
    const workspace = port.workspace();
    try {
      entry.guard(entry.request.pluginId);
    } catch {
      return false;
    }
    return (
      !stopped &&
      !entry.controller.signal.aborted &&
      port.windowLabel() === hostLabel &&
      entry.request.hostLabel === hostLabel &&
      !!workspace &&
      workspace.id === entry.request.workspaceId &&
      workspace.path === entry.request.workspacePath
    );
  };
  const cancel = (entry: Pending) => {
    if (entry.controller.signal.aborted) return;
    entry.controller.abort();
    entry.approval.close();
    pending.delete(entry.request.operationId);
    void cancelNative(entry, cancelled);
  };
  const dispose = () => {
    stopped = true;
    for (const entry of pending.values()) cancel(entry);
    for (const cleanup of cleanups.splice(0).reverse()) cleanup();
  };
  try {
    cleanups.push(
      port.subscribeWorkspace(() => {
        for (const entry of pending.values()) if (!current(entry)) cancel(entry);
      }),
    );
    cleanups.push(
      port.subscribePlugin((pluginId) => {
        for (const entry of pending.values())
          if (entry.request.pluginId === pluginId) cancel(entry);
      }),
    );
    // Observe terminal cleanup before accepting a request that can finish.
    cleanups.push(
      await port.listenCancelled((operationId) => {
        const entry = pending.get(operationId);
        if (entry) cancel(entry);
      }),
    );
    cleanups.push(
      await port.listenCleanupFailed(async (failure) => {
        if (!failure || !validContext(failure.context, hostLabel, failure.operationId)) return;
        await retainFailure(failure.context, failure.error);
      }),
    );
    cleanups.push(
      await port.listen(async (request) => {
        if (!valid(request) || request.hostLabel !== hostLabel || pending.has(request.operationId))
          return;
        const controller = new AbortController();
        const entry: Pending = {
          request,
          controller,
          approval: port.approval(),
          guard: port.guard(),
        };
        pending.set(request.operationId, entry);
        try {
          if (!current(entry)) throw cancelled;
          const review = await port.prepare(request);
          if (
            !validContext(review.context, hostLabel, request.operationId) ||
            review.context.pluginId !== request.pluginId ||
            review.context.workspacePath !== request.workspacePath
          )
            throw { code: "plugin.function.staleContext", message: "plugin.function.staleContext" };
          entry.context = { ...review.context };
          if (!current(entry)) throw cancelled;
          if (!(await entry.approval.approve(review, controller.signal))) throw cancelled;
          if (!current(entry)) throw cancelled;
          await port.confirm(request.operationId);
        } catch (error) {
          await cancelNative(entry, functionFailure(error));
        } finally {
          entry.approval.close();
          pending.delete(request.operationId);
        }
      }),
    );
    return dispose;
  } catch (error) {
    dispose();
    throw error;
  }
}
