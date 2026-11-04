import { invoke as nativeInvoke } from "./tauri-core";
import { translatePluginHostFailure } from "@/features/plugins/plugin-native-errors";
import { startBuildProviderDebug, type ProviderDebugOptions, type RegisteredConnectionPlan } from "@/features/debugger/services/build-provider-debug";
import { declarativePluginProcessOwner } from "@/features/plugins/declarative-plugin-process-owner";
import { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import { initializeDebuggerEventBridge } from "@/features/debugger/services/debug-adapter-events";
import { startRegisteredConnectionDebugSession, stopDebugAdapterSession } from "@/features/debugger/services/debug-adapter-service";
import { registerDebugSessionCleanup } from "@/features/debugger/services/debug-session-resources";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { requestPluginDebugEndpoint } from "./lsp-core-adapter";
import { prepareNativeBuildTool } from "./build-tool-preparation";
import { PRIMARY_SESSION_ID, type RunProcessInstance } from "@/features/run/types/run.types";
import { useRunStore } from "@/features/run/stores/run.store";
import { ensureRunProcessListeners } from "@/features/run/hooks/use-run-process-events";
import { frontendTrace } from "@/utils/frontend-trace";

function invoke<T>(...args: Parameters<typeof nativeInvoke>): Promise<T> {
  return nativeInvoke<T>(...args).catch(cause => { throw translatePluginHostFailure(cause,createTranslator(useSettingsStore.getState().settings.displayLanguage)); });
}

let starting = false;

/** Product composition only. The service owns ordering and the same Run store
 * used by ordinary Provider runs owns the debuggee process and its output. */
export async function startWindowsBuildProviderDebug(request: {
  workspaceId: string; root: string; name: string; configurationType: string; preferredAdapterID?: string;
  assertCurrent: () => void; signal: AbortSignal;
  startRun: (options: ProviderDebugOptions, assertCurrent: () => void, signal: AbortSignal) => Promise<RunProcessInstance | null>;
  stopRun: (instance: RunProcessInstance) => Promise<void>;
}): Promise<void> {
  const unavailable = () => new Error(createTranslator(useSettingsStore.getState().settings.displayLanguage)("build.errors.inputsChanged"));
  const available = () => {
    request.assertCurrent(); request.signal.throwIfAborted();
    const active = useDebuggerStore.getState().activeSession;
    if (active && active.status !== "idle") throw unavailable();
  };
  available(); if (starting) throw unavailable(); starting = true;
  let selected: RegisteredConnectionPlan | undefined;
  const nativeRequest = (port: number) => ({ workspacePath: request.root, configurationType: request.configurationType,
    preferredAdapterID: request.preferredAdapterID ?? selected?.adapterID ?? null, port });
  let ownSession: string | undefined;
  const handle = startBuildProviderDebug({ ...request, isCurrent: () => {
    try { request.assertCurrent(); return true; } catch { return false; }
  } }, {
    processes: declarativePluginProcessOwner, guard: pluginPlanGuard, unavailable,
    allocatePort: async () => { available(); return invoke<number>("debug_allocate_loopback_port"); },
    plan: async (_, port) => { available(); selected = await invoke<RegisteredConnectionPlan>("declarative_plugins_debug_connection_plan", { request: nativeRequest(port) }); return selected; },
    validate: plan => invoke<void>("declarative_plugins_debug_validate_connection", { request: nativeRequest(plan.port), identity: plan.identity }),
    startRun: async (options, assertCurrent, signal) => { available(); await ensureRunProcessListeners(); assertCurrent();
      await initializeDebuggerEventBridge(); assertCurrent();
      return request.startRun(options, assertCurrent, signal); },
    stopRun: request.stopRun,
    watchRun: (instance, ended) => {
      const store = useRunStore.getStore(request.workspaceId); let fired = false;
      const check = () => {
        const state = store.getState(), session = state.sessions.find(session => session.id === instance.sessionId);
        const current = instance.sessionId === PRIMARY_SESSION_ID ? state.primaryExecutionId === instance.executionId && state.primaryRunning
          : session?.executionId === instance.executionId && session.isRunning;
        if (!current && !fired) { fired = true; ended(); }
      };
      const unsubscribe = store.subscribe(check); check(); return unsubscribe;
    },
    reportCleanupFailure: error => frontendTrace("error","build.debug","Registry debug cleanup failed",{error:String(error)}),
    waitForPort: (port, signal) => prepareNativeBuildTool({
      begin: () => invoke<string>("declarative_plugins_begin_tool_preparation"),
      resolve: operationId => invoke<void>("debug_wait_for_port", { args: { port, timeoutMilliseconds: 30_000, operationId } }),
      cancel: operationId => invoke<void>("declarative_plugins_cancel_tool_preparation", { operationId }),
    }, signal),
    startAdapter: async (plan, onStarted, assertCurrent, signal) => {
      available();
      const port = plan.adapter.transport === "tcpLanguageServer" ? await requestPluginDebugEndpoint({
        pluginId: plan.pluginId, languageId: plan.languageId!, command: plan.command!, workspacePath: request.root, launch: plan.launch,
      }, assertCurrent, signal) : undefined;
      assertCurrent(); await invoke("declarative_plugins_debug_validate_connection", { request: nativeRequest(plan.port), identity: plan.identity }); assertCurrent();
      return startRegisteredConnectionDebugSession(plan, port, request.name, useDebuggerStore.getState().breakpoints, request.root, onStarted, assertCurrent);
    },
    stopAdapter: async id => {
      await stopDebugAdapterSession(id);
      if (useDebuggerStore.getState().activeSession?.id === id) useDebuggerStore.getState().actions.stopSession();
    },
    onStarted: (session, instance, stop) => {
      available(); ownSession = session.id;
      registerDebugSessionCleanup(session.id, stop);
      useDebuggerStore.getState().actions.startSession({ id: session.id, name: request.name, configId: instance.sessionId,
        command: session.command, cwd: session.cwd, startedAt: Date.now(), status: "running", adapterSession: true });
    },
  });
  try { await handle.completion; }
  catch (error) {
    if (ownSession && useDebuggerStore.getState().activeSession?.id === ownSession) useDebuggerStore.getState().actions.stopSession();
    throw error;
  } finally { starting = false; }
}
