import { invoke } from "@/platform/tauri-core";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { pluginPlanGuard } from "../declarative-plugin-lifecycle";
import { createPluginFunctionSession } from "../plugin-functions";
import type { WebFunctionApproval } from "../plugin-web-function-approval";
import {
  functionFailure,
  type FunctionReview,
  type FunctionState,
} from "../plugin-function-session";
import { nativePanelKey } from "./native-panel-state";
import type { NativeCallContext, NativeFunctionPort, NativePanelIdentity } from "./native-ui.types";

interface Receipt {
  bindingId: string;
  settingIdentity: string;
  packageIdentity: string;
}
export interface NativeFunctionDependencies {
  open(identity: NativePanelIdentity, workspacePath: string): Promise<Receipt>;
  close(bindingId: string): Promise<void>;
  prepare(
    bindingId: string,
    actionId: string | undefined,
    context: NativeCallContext,
    operationId: string,
  ): Promise<FunctionReview>;
  session: typeof createPluginFunctionSession;
  approval(): WebFunctionApproval | Promise<WebFunctionApproval>;
  capture(identity: NativePanelIdentity): { path: string; assertCurrent(): void };
  report(error: unknown): void;
}
const nativeDependencies: NativeFunctionDependencies = {
  open: (identity, workspacePath) =>
    invoke("declarative_plugins_native_function_open", {
      pluginId: identity.pluginId,
      windowId: identity.windowId,
      workspacePath,
      expectedPackageIdentity: identity.packageIdentity,
    }),
  close: (bindingId) => invoke("declarative_plugins_native_function_close", { bindingId }),
  prepare: (bindingId, actionId, context, operationId) =>
    invoke("declarative_plugins_native_function_prepare", {
      request: {
        bindingId,
        actionId: actionId ?? null,
        selectedId: context.selectedID ?? null,
        values: context.values ?? null,
        operationId,
      },
    }),
  session: createPluginFunctionSession,
  approval: async () =>
    (await import("../plugin-web-function-approval")).createWebFunctionApproval(),
  capture: (identity) => {
    const runtime = workspaceRuntimeRegistry.getActiveWorkspace();
    const guard = pluginPlanGuard();
    const assertCurrent = () => {
      guard(identity.pluginId);
      if (
        !runtime?.descriptor.path ||
        runtime.status !== "ready" ||
        runtime.descriptor.id !== identity.workspaceId ||
        workspaceRuntimeRegistry.getActiveWorkspace() !== runtime
      )
        throw new Error("pluginNative.unavailable");
    };
    assertCurrent();
    return { path: runtime!.descriptor.path!, assertCurrent };
  },
  report: (error) => console.warn("Native plugin panel cleanup failed", error),
};

/** One mounted contribution retains its exact native handle. The shared
 * session owns approvals, polling and cleanup notices after the panel leaves. */
export function createNativeFunctionPort(
  identity: NativePanelIdentity,
  dependencies = nativeDependencies,
): NativeFunctionPort & { dispose(): void } {
  let closed = false;
  let opening: Promise<Receipt> | undefined;
  let currentBinding: Receipt | undefined;
  let staleBinding: Receipt | undefined;
  let closing: Promise<void> | undefined;
  let scope: ReturnType<NativeFunctionDependencies["capture"]>;
  const sessions = new Set<ReturnType<typeof createPluginFunctionSession>>();
  const listeners = new Set<(progress: FunctionState["progress"]) => void>();
  const assertCurrent = () => {
    if (closed) throw new Error("pluginNative.cancelled");
    scope.assertCurrent();
  };
  const closeStale = () => {
    if (!staleBinding) return Promise.resolve();
    if (closing) return closing;
    const binding = staleBinding;
    closing = dependencies
      .close(binding.bindingId)
      .then(() => {
        if (staleBinding === binding) staleBinding = undefined;
      })
      .finally(() => {
        closing = undefined;
      });
    return closing;
  };
  const receipt = async () => {
    // A new model/settings revision needs a fresh native registration. Retain
    // the old handle until its process owners have actually been reclaimed.
    if (staleBinding) await closeStale();
    if (closed) throw new Error("pluginNative.cancelled");
    if (!opening) {
      scope = dependencies.capture(identity);
      opening = dependencies
        .open(identity, scope.path)
        .then((binding) => {
          currentBinding = binding;
          return binding;
        })
        .catch((error) => {
          opening = undefined;
          throw error;
        });
    }
    return opening;
  };
  const run = async (
    context: NativeCallContext,
    signal: AbortSignal,
    binding: Receipt,
    actionId?: string,
  ) => {
    signal.throwIfAborted();
    assertCurrent();
    const approval = await dependencies.approval();
    if (signal.aborted || closed) {
      approval.close();
      signal.throwIfAborted();
      throw new Error("pluginNative.cancelled");
    }
    const session = dependencies.session(
      {
        pluginId: identity.pluginId,
        actionId: `__native__:${binding.bindingId}:${actionId ?? ""}`,
        workspacePath: scope.path,
        expectedIdentity: binding.settingIdentity,
        operationId: crypto.randomUUID(),
      },
      assertCurrent,
      (state) => {
        for (const listener of listeners) listener(state.progress);
      },
      {
        prepare: (input) =>
          dependencies.prepare(binding.bindingId, actionId, context, input.operationId),
      },
    );
    sessions.add(session);
    const abort = () => {
      approval.close();
      session.dispose();
    };
    signal.addEventListener("abort", abort, { once: true });
    try {
      if (signal.aborted) abort();
      await session.prepare();
      signal.throwIfAborted();
      assertCurrent();
      if (session.state.phase !== "review" || !session.state.review)
        throw session.state.error ?? new Error("pluginNative.failed");
      if (
        session.state.review.context.packageIdentity !== binding.packageIdentity ||
        session.state.review.context.window !== identity.hostWindowId
      )
        throw new Error("pluginNative.unavailable");
      if (!(await approval.approve(session.state.review, signal)))
        throw new Error("pluginNative.cancelled");
      signal.throwIfAborted();
      assertCurrent();
      await session.confirm();
      signal.throwIfAborted();
      assertCurrent();
      if ((session.state as FunctionState).phase !== "succeeded")
        throw session.state.error ?? new Error("pluginNative.failed");
      return session.state.result;
    } finally {
      signal.removeEventListener("abort", abort);
      session.dispose();
      sessions.delete(session);
      approval.close();
    }
  };
  const call = async (context: NativeCallContext, signal: AbortSignal, actionId?: string) => {
    let binding: Receipt | undefined;
    try {
      signal.throwIfAborted();
      if (closed || nativePanelKey(context.identity) !== nativePanelKey(identity))
        throw new Error("pluginNative.unavailable");
      binding = await receipt();
      return await run(context, signal, binding, actionId);
    } catch (error) {
      const code = functionFailure(error).code;
      if (
        binding &&
        currentBinding === binding &&
        ["plugin.function.staleContext", "plugin.settings.conflict"].includes(code)
      ) {
        staleBinding = binding;
        currentBinding = undefined;
        opening = undefined;
      }
      if (
        [
          "plugin.function.unavailable",
          "plugin.function.providerUnavailable",
          "plugin.function.staleContext",
          "plugin.function.unknown",
        ].includes(code)
      )
        throw Object.assign(new Error("pluginNative.unavailable"), { cause: error });
      if (["plugin.function.invalidResult", "plugin.function.resultTooLarge"].includes(code))
        throw Object.assign(new Error("pluginNative.invalidData"), { cause: error });
      throw error;
    }
  };
  return {
    load: (context, signal) => call(context, signal),
    invoke: (action, context, signal) => call(context, signal, action.id),
    subscribeProgress: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    dispose() {
      if (closed) return;
      closed = true;
      for (const session of sessions) session.dispose();
      listeners.clear();
      // Join a late registration and close only its captured native token.
      void opening
        ?.then((binding) => dependencies.close(binding.bindingId))
        .catch(dependencies.report);
      void closeStale().catch(dependencies.report);
    },
  };
}
