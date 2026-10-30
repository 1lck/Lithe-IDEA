import { afterAll, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import * as deferredWork from "@/features/editor/lsp/deferred-lsp-work";
import { LspClient } from "@/features/editor/lsp/lsp-client";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { useLspIntegration } = await import("./use-lsp-integration");

function mockNativeInvoke(
  handler: (command: string, args?: Parameters<typeof native.invoke>[1]) => Promise<unknown>,
) {
  return spyOn(native, "invoke").mockImplementation(
    async <T,>(command: string, args?: Parameters<typeof native.invoke>[1]): Promise<T> =>
      (await handler(command, args)) as T,
  );
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function Editor({ path }: { path: string }) {
  useLspIntegration({ filePath: path });
  return null;
}

test("a native-only language passes the editor admission gate and opens its LSP document", async () => {
  const pluginId = "io.example.hook-activation";
  setPluginActive(pluginId, true);
  const answer = deferred<{ pluginId: string; displayName: string; languageId: string } | null>();
  const entered = deferred<void>();
  const scheduled = new Set<() => void>();
  const scheduling = spyOn(deferredWork, "deferUntilAfterNextPaint").mockImplementation(
    (callback) => {
      scheduled.add(callback);
      return () => {
        scheduled.delete(callback);
      };
    },
  );
  const starts: string[] = [];
  const opened: string[] = [];
  const stopped: string[] = [];
  const client = {
    startForFile: async (path: string) => {
      starts.push(path);
      return { kind: "attached", attachmentId: "fixture-attachment" };
    },
    notifyDocumentOpen: async (path: string) => {
      opened.push(path);
    },
    notifyDocumentClose: async () => {},
    stopForFile: async (path: string) => {
      stopped.push(path);
    },
  } as unknown as LspClient;
  const instance = spyOn(LspClient, "getInstance").mockReturnValue(client);
  const invoke = mockNativeInvoke(async (command) => {
    if (command === "declarative_plugins_language_owner") {
      entered.resolve();
      return answer.promise;
    }
    throw new Error(`unexpected native command ${command}`);
  });
  const host = document.createElement("div");
  const root = createRoot(host);
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const path = "C:/fixture/main.hookactivation";
    await act(async () => root.render(<Editor path={path} />));
    await entered.promise;
    expect(starts).toEqual([]);
    await act(async () =>
      answer.resolve({ pluginId, displayName: "Fixture", languageId: "hookactivation" }),
    );
    expect(scheduled.size).toBe(1);
    await act(async () => {
      for (const callback of scheduled) callback();
      scheduled.clear();
    });
    expect(starts).toEqual([path]);
    expect(opened).toEqual([path]);
    await act(async () => setPluginActive(pluginId, false));
    expect(stopped).toEqual([path]);
  } finally {
    answer.resolve(null);
    await act(async () => root.unmount());
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    setPluginActive(pluginId, false);
    scheduled.clear();
    invoke.mockRestore();
    instance.mockRestore();
    scheduling.mockRestore();
    host.remove();
  }
});

test("unclaimed or virtual editor files never schedule a server start", async () => {
  const scheduled: Array<() => void> = [];
  const scheduling = spyOn(deferredWork, "deferUntilAfterNextPaint").mockImplementation(
    (callback) => {
      scheduled.push(callback);
      return () => {};
    },
  );
  const entered = deferred<void>();
  const invoke = mockNativeInvoke(async (command) => {
    expect(command).toBe("declarative_plugins_language_owner");
    entered.resolve();
    return null;
  });
  const client = spyOn(LspClient, "getInstance").mockReturnValue({} as LspClient);
  const root = createRoot(document.createElement("div"));
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  try {
    await act(async () => root.render(<Editor path="C:/fixture/no-owner.hookactivation" />));
    await entered.promise;
    await act(async () => root.render(<Editor path="remote://host/main.hookactivation" />));
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(scheduled).toEqual([]);
  } finally {
    await act(async () => root.unmount());
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    invoke.mockRestore();
    client.mockRestore();
    scheduling.mockRestore();
  }
});
