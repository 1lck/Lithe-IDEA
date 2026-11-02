import {
  PluginFunctionSession,
  type FunctionContext,
  type FunctionInput,
  type FunctionReview,
  type FunctionSnapshot,
} from "../plugin-function-session";
import { createNativeFunctionPort, type NativeFunctionDependencies } from "./native-functions";
import type { NativeCallContext, NativePanelIdentity, NativeUI } from "./native-ui.types";
import type { WebFunctionApproval } from "../plugin-web-function-approval";

export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

/** Real function sessions with a controlled native boundary; no provider,
 * clock, native process or user workspace participates in these tests. */
export function nativeFunctionFixture(identity: NativePanelIdentity, ui: NativeUI) {
  const calls: Array<{
    bindingId: string;
    actionId?: string;
    context: NativeCallContext;
    operationId: string;
  }> = [];
  const closed: string[] = [];
  const confirmed: string[] = [];
  const cancelled: string[] = [];
  const owners = new Set<PluginFunctionSession>();
  const sessions: PluginFunctionSession[] = [];
  let current = true;
  let cleanupFails = false;
  let prepareGate: Promise<void> | undefined;
  let wait = async (_signal: AbortSignal): Promise<void> => {
    throw new Error("Test must provide a terminal read or controlled gate");
  };
  let approve: WebFunctionApproval["approve"] = async () => true;
  let read: (context: FunctionContext) => Promise<FunctionSnapshot> = async (context) => ({
    context,
    phase: "succeeded",
    result: { nodes: [] },
  });
  const contexts = new Map<string, FunctionContext>();
  const review = (input: FunctionInput, functionId: string): FunctionReview => ({
    context: {
      ...input,
      window: identity.hostWindowId,
      windowIncarnation: 7,
      generation: 3,
      packageIdentity: "snapshot-bytes",
      settingIdentity: input.expectedIdentity,
      functionId,
    },
    title: functionId,
    confirm: true,
    executesProjectCode: true,
    mayUseNetwork: false,
    program: { serverPath: "/fixture/provider" },
    launchPlan: {},
  });
  const deps: NativeFunctionDependencies = {
    open: async () => ({
      bindingId: "binding-one",
      settingIdentity: "settings-bytes",
      packageIdentity: "snapshot-bytes",
    }),
    close: async (id) => {
      closed.push(id);
    },
    prepare: async (bindingId, actionId, context, operationId) => {
      calls.push({ bindingId, actionId, context, operationId });
      await prepareGate;
      const value = review(
        {
          pluginId: identity.pluginId,
          actionId: `__native__:${bindingId}:${actionId ?? ""}`,
          operationId,
          workspacePath: "/fixture/workspace",
          expectedIdentity: "settings-bytes",
        },
        actionId
          ? ui.actions.find((action) => action.id === actionId)!.function!
          : ui.source!.function,
      );
      contexts.set(operationId, value.context);
      return value;
    },
    session: (input, assertCurrent, publish, overrides) => {
      const session = new PluginFunctionSession(
        input,
        {
          prepare: overrides!.prepare!,
          assertCurrent,
          confirm: async (id) => {
            confirmed.push(id);
          },
          read: (id) => read(contexts.get(id)!),
          cancel: async (id) => {
            cancelled.push(id);
            if (cleanupFails) throw new Error("fixture.cleanupFailed");
          },
          wait: (signal) => wait(signal),
          deadline: () => () => {},
        },
        publish,
        (owner, retained) => {
          if (retained) owners.add(owner);
          else owners.delete(owner);
        },
      );
      sessions.push(session);
      return session;
    },
    approval: () => ({ approve: (value, signal) => approve(value, signal), close: () => {} }),
    capture: () => ({
      path: "/fixture/workspace",
      assertCurrent: () => {
        if (!current) throw new Error("fixture.stale");
      },
    }),
    report: () => {},
  };
  const port = createNativeFunctionPort(identity, deps);
  return {
    port,
    deps,
    calls,
    closed,
    confirmed,
    cancelled,
    owners,
    sessions,
    setApproval: (value: typeof approve) => {
      approve = value;
    },
    setRead: (value: typeof read) => {
      read = value;
    },
    setPrepareGate: (value: Promise<void>) => {
      prepareGate = value;
    },
    setWait: (value: typeof wait) => {
      wait = value;
    },
    setCleanupFailure: (value: boolean) => {
      cleanupFails = value;
    },
    stale: () => {
      current = false;
    },
    async close() {
      cleanupFails = false;
      port.dispose();
      await Promise.all(sessions.map((session) => session.cancel()));
    },
  };
}
