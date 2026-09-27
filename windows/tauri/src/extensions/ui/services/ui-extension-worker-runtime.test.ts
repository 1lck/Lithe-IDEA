import { afterEach, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import type { ExtensionWorkerMessage } from "./ui-extension-worker";

let disposeWorker: (() => void) | undefined;
afterEach(() => {
  disposeWorker?.();
  disposeWorker = undefined;
});

test("independent PHP entrypoint activates in a worker and contributes plans over the host protocol", async () => {
  const source = await readFile(
    new URL("../../../../../../Plugins/win/Official/PhpSupport/plugin.ts", import.meta.url),
    "utf8",
  );
  const javascript = new Bun.Transpiler({ loader: "ts" }).transformSync(source);
  const entryPointUrl = URL.createObjectURL(new Blob([javascript], { type: "text/javascript" }));
  const worker = new Worker(new URL("./ui-extension-worker-runtime.ts", import.meta.url).href, {
    type: "module",
  });
  const pending = new Map<
    string,
    { resolve: (value: ExtensionWorkerMessage) => void; reject: (error: Error) => void }
  >();
  // The framework's local deadline runs teardown even when a worker never replies.
  disposeWorker = () => {
    worker.terminate();
    URL.revokeObjectURL(entryPointUrl);
    for (const request of pending.values()) request.reject(new Error("Worker test disposed"));
    pending.clear();
  };
  const receive = (key: string) =>
    new Promise<ExtensionWorkerMessage>((resolve, reject) => pending.set(key, { resolve, reject }));
  worker.addEventListener("message", (event: MessageEvent<ExtensionWorkerMessage>) => {
    const message = event.data;
    const key =
      message.type === "event"
        ? message.event
        : message.type === "response"
          ? String(message.id)
          : "";
    pending.get(key)?.resolve(message);
    pending.delete(key);
    if (message.type === "event" && message.event === "activation.error") {
      for (const request of pending.values())
        request.reject(new Error(String(message.payload?.message)));
      pending.clear();
    }
  });
  worker.addEventListener("error", (event) => {
    for (const request of pending.values()) request.reject(new Error(event.message));
    pending.clear();
  });
  try {
    const ready = receive("ready");
    worker.postMessage({ type: "activate", entryPointUrl });
    await ready;
    const discovered = receive("1");
    worker.postMessage({
      type: "worker-call",
      id: 1,
      method: "discoverRunActions",
      params: [{ "phpunit.xml": "<phpunit/>" }],
    });
    expect(await discovered).toMatchObject({
      type: "response",
      id: 1,
      result: [{ id: "phpunit", executable: "php", arguments: ["vendor/bin/phpunit"] }],
    });
    const deactivated = receive("2");
    worker.postMessage({ type: "worker-call", id: 2, method: "deactivate", params: [] });
    await deactivated;
    const empty = receive("3");
    worker.postMessage({
      type: "worker-call",
      id: 3,
      method: "discoverRunActions",
      params: [{ "phpunit.xml": "" }],
    });
    expect(await empty).toMatchObject({ result: [] });
  } finally {
    disposeWorker?.();
    disposeWorker = undefined;
  }
}, 2000);
