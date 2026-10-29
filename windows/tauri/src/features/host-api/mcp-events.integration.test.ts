import { afterEach, expect, test } from "bun:test";
import { openIdeConnection } from "@/platform/ide-request-events";

// Run in its own Bun process: these tests exercise the real Tauri event API,
// including callback registration/unregistration, without module mocks or a VM.
const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });

function nativeBoundary(failOpen = false) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "window");
  const callbacks = new Map<number, (event: unknown) => void>();
  const listeners = new Map<number, number>();
  const calls: string[] = [];
  let sequence = 0;
  let target: unknown;
  const send = (payload: unknown) => {
    for (const [id, callback] of listeners) callbacks.get(callback)?.({
      event: "lithe-ide-request", id, payload,
    });
  };
  Object.defineProperty(globalThis, "window", { configurable: true, value: {
    __TAURI_INTERNALS__: {
      metadata: { currentWindow: { label: "project-window" }, currentWebview: { label: "project-view" } },
      transformCallback: (callback: (event: unknown) => void) => {
        const id = ++sequence;
        callbacks.set(id, callback);
        return id;
      },
      invoke: async (command: string, args: Record<string, unknown>) => {
        calls.push(command);
        if (command === "plugin:event|listen") {
          expect(args.event).toBe("lithe-ide-request");
          target = args.target;
          const id = ++sequence;
          listeners.set(id, args.handler as number);
          return id;
        }
        if (command === "plugin:event|unlisten") return;
        expect(command).toBe("platform_invoke");
        expect(args.command).toBe("ideHost.control");
        expect(args.args).toEqual({ action: "open", arguments: { workspaceKey: "fixture" } });
        expect(listeners.size).toBe(1);
        if (failOpen) throw new Error("fixture open failure");
        send({ hostID: "host", requestID: "before-open-response" });
        return { hostID: "host", configuration: {} };
      },
    },
    __TAURI_EVENT_PLUGIN_INTERNALS__: {
      unregisterListener: (_event: string, id: number) => {
        callbacks.delete(listeners.get(id)!);
        listeners.delete(id);
      },
    },
  } });
  cleanups.push(() => {
    callbacks.clear();
    listeners.clear();
    if (previous) Object.defineProperty(globalThis, "window", previous);
    else Reflect.deleteProperty(globalThis, "window");
  });
  return { calls, callbacks, listeners, send, target: () => target };
}

test("real Tauri events survive missing notifications and release callbacks independently", async () => {
  const native = nativeBoundary();
  const received: string[] = [];
  const connection = await openIdeConnection({ workspaceKey: "fixture" }, async (event) => {
    received.push(event.requestID);
  });
  try {
    expect(native.target()).toEqual({ kind: "Webview", label: "project-view" });
    // The first request after open is lost before delivery. Later notifications
    // still arrive: there is no Channel sequence index to wait for or replay.
    native.send({ hostID: "host", requestID: "second" });
    native.send({ hostID: "host", requestID: "third" });
    native.send({ requestID: "invalid-without-host" });
    expect(received).toEqual(["before-open-response", "second", "third"]);
  } finally {
    await connection.dispose();
  }
  expect(native.listeners.size).toBe(0);
  expect(native.callbacks.size).toBe(0);
  native.send({ hostID: "host", requestID: "after-close" });
  expect(received).toHaveLength(3);
}, 1000);

test("failed native open removes the already registered event listener", async () => {
  const native = nativeBoundary(true);
  await expect(openIdeConnection({ workspaceKey: "fixture" }, async () => {}))
    .rejects.toThrow("fixture open failure");
  expect(native.listeners.size).toBe(0);
  expect(native.callbacks.size).toBe(0);
  expect(native.calls).toEqual(["plugin:event|listen", "platform_invoke", "plugin:event|unlisten"]);
}, 1000);
