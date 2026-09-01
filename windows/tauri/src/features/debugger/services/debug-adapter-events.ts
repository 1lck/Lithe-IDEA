import {
  sendDebugAdapterRequest,
  subscribeDebuggerEvents,
} from "@/features/debugger/services/debug-adapter-service";
import { useDebuggerStore } from "@/features/debugger/stores/debugger.store";
import type {
  DebugProtocolMessage,
  DebugRequestContext,
  DebugScope,
  DebugStackFrame,
  DebugThread,
  DebugVariable,
} from "@/features/debugger/types/debugger.types";

let unsubscribeDebuggerEvents: (() => void) | null = null;
let pendingSubscription: Promise<void> | null = null;

export function initializeDebuggerEventBridge(): Promise<void> {
  if (unsubscribeDebuggerEvents) return Promise.resolve();
  if (pendingSubscription) return pendingSubscription;

  pendingSubscription = subscribeDebuggerEvents({
    onMessage: (message) => {
      useDebuggerStore.getState().actions.recordAdapterMessage(message);
      void handleDebugProtocolMessage(message);
    },
    onOutput: (output) => useDebuggerStore.getState().actions.recordAdapterOutput(output),
    onSessionEnded: (event) => useDebuggerStore.getState().actions.recordSessionEnded(event),
  })
    .then((unlisten) => {
      unsubscribeDebuggerEvents = unlisten;
    })
    .finally(() => {
      pendingSubscription = null;
    });

  return pendingSubscription;
}

// Rust Core emits normalized events only: no DAP frames, request sequences, or
// response correlation exist in the React layer.
async function handleDebugProtocolMessage(payload: DebugProtocolMessage) {
  const event = asRecord(payload.message);
  if (!event) return;

  switch (event.type) {
    case "stateChanged":
      handleStateChanged(event);
      return;
    case "stopped":
      await handleStopped(payload.sessionId, event);
      return;
    case "continued":
      handleContinued();
      return;
    case "terminated":
      useDebuggerStore.getState().actions.recordSessionEnded({
        sessionId: payload.sessionId,
        reason: "terminated",
      });
      return;
    case "output":
      handleOutput(payload.sessionId, event);
      return;
    case "operationCompleted":
      await handleOperationCompleted(payload.sessionId, event);
      return;
    case "operationFailed":
      handleOperationFailed(event);
      return;
  }
}

function handleStateChanged(event: Record<string, unknown>) {
  const state = typeof event.state === "string" ? event.state : "";
  if (state === "paused") {
    useDebuggerStore.getState().actions.setSessionStatus("paused");
  } else if (state === "running") {
    useDebuggerStore.getState().actions.setSessionStatus("running");
  }
}

async function handleStopped(sessionId: string, event: Record<string, unknown>) {
  const threadId = typeof event.threadId === "number" ? event.threadId : undefined;
  const actions = useDebuggerStore.getState().actions;
  actions.setSessionStatus("paused");
  actions.setStoppedState({
    reason: typeof event.reason === "string" ? event.reason : "stopped",
    threadId,
    description: typeof event.description === "string" ? event.description : undefined,
  });

  if (typeof threadId === "number") {
    await requestStackTrace(sessionId, threadId);
  } else {
    await requestThreads(sessionId);
  }
}

function handleContinued() {
  const actions = useDebuggerStore.getState().actions;
  actions.setSessionStatus("running");
  actions.setStoppedState(null);
}

function handleOutput(sessionId: string, event: Record<string, unknown>) {
  const output = typeof event.output === "string" ? event.output : "";
  if (!output) return;
  useDebuggerStore.getState().actions.recordAdapterOutput({
    sessionId,
    stream: typeof event.category === "string" ? event.category : "stdout",
    data: output,
  });
}

async function handleOperationCompleted(sessionId: string, event: Record<string, unknown>) {
  const operationId = typeof event.operationId === "string" ? event.operationId : "";
  const result = asRecord(event.result);
  const kind = typeof result?.kind === "string" ? result.kind : "";
  const store = useDebuggerStore.getState();
  const context = operationId ? store.pendingRequests[operationId] : undefined;
  if (operationId) {
    store.actions.clearAdapterRequest(operationId);
  }

  switch (kind) {
    case "threads": {
      const threads = toThreads(result?.threads);
      store.actions.setThreads(threads);
      const firstThreadId = threads[0]?.id;
      if (typeof firstThreadId === "number") {
        await requestStackTrace(sessionId, firstThreadId);
      }
      return;
    }
    case "stackTrace": {
      const frames = toStackFrames(result?.stackFrames);
      store.actions.setStackFrames(frames);
      const firstFrameId = frames[0]?.id;
      if (typeof firstFrameId === "number") {
        await requestScopes(sessionId, firstFrameId);
      }
      return;
    }
    case "scopes": {
      const scopes = toScopes(result?.scopes);
      store.actions.setScopes(scopes);
      await Promise.all(
        scopes
          .filter((scope) => scope.variablesReference > 0)
          .map((scope) => requestVariables(sessionId, scope.variablesReference)),
      );
      return;
    }
    case "variables": {
      if (context?.command === "variables") {
        store.actions.setVariables(context.variablesReference, toVariables(result?.variables));
      }
      return;
    }
    case "evaluate": {
      if (context?.command === "evaluate") {
        const variable = asRecord(result?.variable);
        store.actions.setWatchResult({
          expressionId: context.expressionId,
          value: typeof variable?.value === "string" ? variable.value : "",
          type: typeof variable?.type === "string" ? variable.type : undefined,
          variablesReference:
            typeof variable?.variablesReference === "number" ? variable.variablesReference : 0,
          evaluatedAt: Date.now(),
        });
      }
      return;
    }
  }
}

function handleOperationFailed(event: Record<string, unknown>) {
  const operationId = typeof event.operationId === "string" ? event.operationId : "";
  const store = useDebuggerStore.getState();
  const context = operationId ? store.pendingRequests[operationId] : undefined;
  if (operationId) {
    store.actions.clearAdapterRequest(operationId);
  }
  if (context?.command === "evaluate") {
    store.actions.setWatchResult({
      expressionId: context.expressionId,
      value: "",
      variablesReference: 0,
      error: typeof event.message === "string" ? event.message : "Could not evaluate expression.",
      evaluatedAt: Date.now(),
    });
  }
}

async function requestThreads(sessionId: string) {
  const result = await sendDebugAdapterRequest(sessionId, "threads");
  registerContext(result.operationId, { command: "threads" });
}

async function requestStackTrace(sessionId: string, threadId: number) {
  const result = await sendDebugAdapterRequest(sessionId, "stackTrace", { threadId });
  registerContext(result.operationId, { command: "stackTrace", threadId });
}

async function requestScopes(sessionId: string, frameId: number) {
  const result = await sendDebugAdapterRequest(sessionId, "scopes", { frameId });
  registerContext(result.operationId, { command: "scopes", frameId });
}

async function requestVariables(sessionId: string, variablesReference: number) {
  const result = await sendDebugAdapterRequest(sessionId, "variables", { variablesReference });
  registerContext(result.operationId, { command: "variables", variablesReference });
}

function registerContext(operationId: string, context: DebugRequestContext) {
  if (!operationId) return;
  useDebuggerStore.getState().actions.registerAdapterRequest(operationId, context);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function toThreads(value: unknown): DebugThread[] {
  if (!Array.isArray(value)) return [];

  return value
    .map((item): DebugThread | null => {
      const thread = asRecord(item);
      if (!thread || typeof thread.id !== "number") return null;
      return {
        id: thread.id,
        name: typeof thread.name === "string" ? thread.name : `Thread ${thread.id}`,
      };
    })
    .filter((thread): thread is DebugThread => Boolean(thread));
}

function toStackFrames(value: unknown): DebugStackFrame[] {
  if (!Array.isArray(value)) return [];

  return value
    .map((item): DebugStackFrame | null => {
      const frame = asRecord(item);
      if (!frame || typeof frame.id !== "number") return null;
      return {
        id: frame.id,
        name: typeof frame.name === "string" ? frame.name : `Frame ${frame.id}`,
        sourcePath: typeof frame.sourcePath === "string" ? frame.sourcePath : undefined,
        line: typeof frame.line === "number" ? frame.line : 0,
        column: typeof frame.column === "number" ? frame.column : 0,
      };
    })
    .filter((frame): frame is DebugStackFrame => Boolean(frame));
}

function toScopes(value: unknown): DebugScope[] {
  if (!Array.isArray(value)) return [];

  return value
    .map((item): DebugScope | null => {
      const scope = asRecord(item);
      if (!scope || typeof scope.variablesReference !== "number") return null;
      return {
        name: typeof scope.name === "string" ? scope.name : "Scope",
        variablesReference: scope.variablesReference,
        expensive: typeof scope.expensive === "boolean" ? scope.expensive : undefined,
      };
    })
    .filter((scope): scope is DebugScope => Boolean(scope));
}

function toVariables(value: unknown): DebugVariable[] {
  if (!Array.isArray(value)) return [];

  return value
    .map((item): DebugVariable | null => {
      const variable = asRecord(item);
      if (!variable || typeof variable.name !== "string") return null;
      return {
        name: variable.name,
        value: typeof variable.value === "string" ? variable.value : "",
        type: typeof variable.type === "string" ? variable.type : undefined,
        variablesReference:
          typeof variable.variablesReference === "number" ? variable.variablesReference : 0,
      };
    })
    .filter((variable): variable is DebugVariable => Boolean(variable));
}
