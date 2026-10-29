import { expect, test } from "bun:test";
import { deferred, nativeFunctionFixture } from "./native-functions.test-support";
import { createNativeFunctionPort } from "./native-functions";
import type { NativeCallContext, NativePanelIdentity, NativeUI } from "./native-ui.types";
import fixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json";

const ui = fixture.ui.toolWindows[0].native as unknown as NativeUI;
const identity: NativePanelIdentity = {
  pluginId: fixture.id,
  packageIdentity: "catalog-bytes",
  hostWindowId: "main",
  workspaceId: "workspace",
  windowId: fixture.ui.toolWindows[0].id,
  panelId: ui.id,
};
const context: NativeCallContext = {
  identity,
  source: ui.source!,
  values: Object.fromEntries(ui.controls!.map((control) => [control.id, control.value])),
};

test("typed native source and actions share consent and cleanup without accepting a frontend function or program", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const reviews: string[] = [];
  f.setApproval(async (review) => {
    reviews.push(review.context.functionId);
    return true;
  });
  try {
    expect(await f.port.load(context, new AbortController().signal)).toEqual({ nodes: [] });
    const action = ui.actions.find((action) => action.kind === "invoke")!;
    await f.port.invoke(
      { ...action, function: "frontend.cannot.choose" },
      context,
      new AbortController().signal,
    );
    expect(reviews).toEqual([ui.source!.function, action.function!]);
    expect(f.calls[0].actionId).toBeUndefined();
    expect(f.calls[1].actionId).toBe(action.id);
    expect(f.calls[1].context.values).toEqual(context.values);
    expect(f.confirmed).toHaveLength(2);
    expect(f.cancelled).toHaveLength(2);
    expect(f.owners.size).toBe(0);
  } finally {
    await f.close();
  }
}, 1000);

test("native load approval refusal cancels its exact receipt before a provider can start", async () => {
  const f = nativeFunctionFixture(identity, ui);
  f.setApproval(async () => false);
  try {
    await expect(f.port.load(context, new AbortController().signal)).rejects.toThrow(
      "pluginNative.cancelled",
    );
    await Promise.all(f.sessions.map((session) => session.cancel()));
    expect(f.confirmed).toHaveLength(0);
    expect(f.cancelled).toEqual([f.calls[0].operationId]);
    expect(f.owners.size).toBe(0);
  } finally {
    await f.close();
  }
}, 1000);

test("an unavailable native provider can retry registration without confirming the failed attempt", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const open = f.deps.open;
  let attempts = 0;
  f.deps.open = (...args) => {
    if (++attempts === 1)
      return Promise.reject({ code: "plugin.function.providerUnavailable", message: "missing" });
    return open(...args);
  };
  try {
    await expect(f.port.load(context, new AbortController().signal)).rejects.toThrow(
      "pluginNative.unavailable",
    );
    expect(f.confirmed).toHaveLength(0);
    expect(await f.port.load(context, new AbortController().signal)).toEqual({ nodes: [] });
    expect(attempts).toBe(2);
    expect(f.confirmed).toHaveLength(1);
    expect(f.owners.size).toBe(0);
  } finally {
    await f.close();
  }
}, 1000);

test("invalid and oversized native results show the panel data error and retain their native cause", async () => {
  const f = nativeFunctionFixture(identity, ui);
  try {
    for (const code of ["plugin.function.invalidResult", "plugin.function.resultTooLarge"]) {
      const failure = { code, message: code };
      f.setRead(async (context) => ({ context, phase: "failed", error: failure }));
      await expect(f.port.load(context, new AbortController().signal)).rejects.toMatchObject({
        message: "pluginNative.invalidData",
        cause: failure,
      });
      expect(f.owners.size).toBe(0);
    }
  } finally {
    await f.close();
  }
}, 1000);

test("retry replaces a successful native registration after its model or settings revision expires", async () => {
  const f = nativeFunctionFixture(identity, ui);
  let registrations = 0;
  f.deps.open = async () => ({
    bindingId: `binding-${++registrations}`,
    settingIdentity: "settings-bytes",
    packageIdentity: "snapshot-bytes",
  });
  const prepare = f.deps.prepare;
  let staleCode: string | undefined;
  f.deps.prepare = (...args) =>
    staleCode ? Promise.reject({ code: staleCode, message: staleCode }) : prepare(...args);
  try {
    await f.port.load(context, new AbortController().signal);
    for (const code of ["plugin.function.staleContext", "plugin.settings.conflict"]) {
      const expired = `binding-${registrations}`;
      staleCode = code;
      await expect(f.port.load(context, new AbortController().signal)).rejects.toBeTruthy();
      staleCode = undefined;
      expect(await f.port.load(context, new AbortController().signal)).toEqual({ nodes: [] });
      expect(f.closed).toContain(expired);
      expect(f.calls[f.calls.length - 1]?.bindingId).toBe(`binding-${registrations}`);
    }
    expect(registrations).toBe(3);
    expect(f.owners.size).toBe(0);
  } finally {
    staleCode = undefined;
    await f.close();
  }
}, 1000);

test("retry cannot replace a stale native handle until the original binding cleanup succeeds", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const prepare = f.deps.prepare;
  const open = f.deps.open;
  const close = f.deps.close;
  let registrations = 0;
  let stale = false;
  let cleanupFails = true;
  f.deps.open = (...args) => {
    registrations++;
    return open(...args);
  };
  f.deps.prepare = (...args) =>
    stale
      ? Promise.reject({ code: "plugin.function.staleContext", message: "expired" })
      : prepare(...args);
  f.deps.close = async (id) => {
    if (cleanupFails) throw { code: "plugin.function.cleanupFailed", message: "cleanup failed" };
    await close(id);
  };
  try {
    await f.port.load(context, new AbortController().signal);
    stale = true;
    await expect(f.port.load(context, new AbortController().signal)).rejects.toBeTruthy();
    stale = false;
    await expect(f.port.load(context, new AbortController().signal)).rejects.toMatchObject({
      code: "plugin.function.cleanupFailed",
    });
    expect(registrations).toBe(1);
    cleanupFails = false;
    expect(await f.port.load(context, new AbortController().signal)).toEqual({ nodes: [] });
    expect(registrations).toBe(2);
    expect(f.closed).toEqual(["binding-one"]);
    expect(f.owners.size).toBe(0);
  } finally {
    cleanupFails = false;
    stale = false;
    await f.close();
  }
}, 1000);

test("cancel during native prepare joins the late receipt and never confirms it", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const gate = deferred<void>();
  const entered = deferred<void>();
  const original = f.deps.prepare;
  f.deps.prepare = (...args) => {
    entered.resolve();
    return original(...args);
  };
  f.setPrepareGate(gate.promise);
  const controller = new AbortController();
  const result = f.port.load(context, controller.signal).catch((error: unknown) => error);
  try {
    await entered.promise;
    controller.abort();
    expect(f.owners.size).toBe(1);
    gate.resolve();
    await result;
    await Promise.all(f.sessions.map((session) => session.cancel()));
    expect(f.confirmed).toHaveLength(0);
    expect(f.cancelled).toEqual([f.calls[0].operationId]);
    expect(f.owners.size).toBe(0);
  } finally {
    gate.resolve();
    entered.resolve();
    await result;
    await f.close();
  }
}, 1000);

test("cancelling an action while approval waits cannot confirm a late acceptance", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const entered = deferred<void>();
  const gate = deferred<boolean>();
  f.setApproval(async () => {
    entered.resolve();
    return gate.promise;
  });
  const controller = new AbortController();
  const action = ui.actions.find((action) => action.kind === "invoke")!;
  const result = f.port.invoke(action, context, controller.signal).catch((error: unknown) => error);
  try {
    await entered.promise;
    controller.abort();
    gate.resolve(true);
    await result;
    expect(f.confirmed).toHaveLength(0);
  } finally {
    entered.resolve();
    gate.resolve(false);
    await result;
    await f.close();
  }
}, 1000);

test("old native result and progress after workspace replacement never reach the caller", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const entered = deferred<void>();
  const gate = deferred<void>();
  f.setRead(async (context) => {
    entered.resolve();
    await gate.promise;
    return { context, phase: "succeeded", result: "old", progress: { message: "old" } };
  });
  const progress: unknown[] = [];
  const stop = f.port.subscribeProgress!((value) => progress.push(value));
  const result = f.port
    .load(context, new AbortController().signal)
    .catch((error: unknown) => error);
  try {
    await entered.promise;
    f.stale();
    gate.resolve();
    expect(await result).toBeTruthy();
    expect(progress).not.toContainEqual({ message: "old" });
    expect(f.owners.size).toBe(0);
  } finally {
    stop();
    entered.resolve();
    gate.resolve();
    await result;
    await f.close();
  }
}, 1000);

test("native backend failure keeps its plugin code and cleanup failure retains the original retry owner", async () => {
  const f = nativeFunctionFixture(identity, ui);
  f.setRead(async (context) => ({
    context,
    phase: "failed",
    error: {
      code: "plugin.function.failed",
      message: "failure",
      pluginErrorCode: "fixture.failed",
    },
  }));
  try {
    await expect(f.port.load(context, new AbortController().signal)).rejects.toMatchObject({
      pluginErrorCode: "fixture.failed",
    });
    f.setCleanupFailure(true);
    await expect(f.port.load(context, new AbortController().signal)).rejects.toBeTruthy();
    await Promise.all(f.sessions.map((session) => session.cancel()));
    expect(f.owners.size).toBe(1);
    f.port.dispose();
    f.setCleanupFailure(false);
    await Promise.all([...f.owners].map((session) => session.cancel()));
    expect(f.owners.size).toBe(0);
  } finally {
    await f.close();
  }
}, 1000);

test("disposing before registration resolves closes only the old handle and leaves a reopened panel usable", async () => {
  const f = nativeFunctionFixture(identity, ui);
  const gate = deferred<{ bindingId: string; settingIdentity: string; packageIdentity: string }>();
  f.deps.open = () => gate.promise;
  const result = f.port
    .load(context, new AbortController().signal)
    .catch((error: unknown) => error);
  f.port.dispose();
  const replacement = createNativeFunctionPort(identity, {
    ...f.deps,
    open: async () => ({
      bindingId: "binding-new",
      settingIdentity: "settings-bytes",
      packageIdentity: "snapshot-bytes",
    }),
  });
  try {
    gate.resolve({
      bindingId: "binding-old",
      settingIdentity: "settings-bytes",
      packageIdentity: "snapshot-bytes",
    });
    await result;
    expect(f.closed).toEqual(["binding-old"]);
    await replacement.load(context, new AbortController().signal);
    expect(f.calls[f.calls.length - 1]?.bindingId).toBe("binding-new");
    expect(f.closed).not.toContain("binding-new");
  } finally {
    gate.resolve({
      bindingId: "binding-old",
      settingIdentity: "settings-bytes",
      packageIdentity: "snapshot-bytes",
    });
    await result;
    replacement.dispose();
    await f.close();
  }
}, 1000);
