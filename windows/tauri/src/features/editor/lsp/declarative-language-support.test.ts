import { afterEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { setPluginActive } from "@/features/plugins/declarative-plugin-lifecycle";
import {
  isEditorLspSupported,
  languageIdForEditorFile,
  resolveEditorLspSupport,
} from "./built-in-language-support";
import { subscribeDeclarativeLanguageSupport } from "./declarative-language-support";
import { resolveEditorLspLaunch } from "./resolve-editor-lsp-launch";

const pluginId = "io.example.editor-admission";
const owner = { pluginId, displayName: "Fixture", languageId: "admission" };
afterEach(() => {
  setPluginActive(pluginId, false);
});

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

test("native-only ownership admits the file and reaches the declarative launch resolver", async () => {
  setPluginActive(pluginId, true);
  const path = "C:/fixture/main.admission";
  const calls: string[] = [];
  const spy = mockNativeInvoke(async (command) => {
    calls.push(command);
    if (command === "declarative_plugins_language_owner") return owner;
    if (command === "declarative_plugins_language_launch")
      return {
        pluginId,
        languageId: "admission",
        serverPath: "C:/fixture/server.exe",
        serverArgs: ["--stdio"],
        initializationOptions: null,
        workspaceConfiguration: null,
        environment: {},
      };
    throw new Error(`unexpected command ${command}`);
  });
  try {
    expect(isEditorLspSupported(path)).toBe(false);
    expect(await resolveEditorLspSupport(path)).toBe(true);
    expect(isEditorLspSupported(path)).toBe(true);
    expect(languageIdForEditorFile(path)).toBe("admission");
    const launch = await resolveEditorLspLaunch(path, {
      workspaceId: "fixture",
      root: "C:/fixture",
    });
    expect(launch?.pluginId).toBe(pluginId);
    expect(launch?.serverPath).toBe("C:/fixture/server.exe");
    expect(calls).toEqual([
      "declarative_plugins_language_owner",
      "declarative_plugins_language_launch",
    ]);
  } finally {
    spy.mockRestore();
  }
});

test("unsupported and virtual documents never reach a launch command", async () => {
  const paths: string[] = [];
  const spy = mockNativeInvoke(async (command, args) => {
    expect(command).toBe("declarative_plugins_language_owner");
    paths.push((args as { filePath: string }).filePath);
    return null;
  });
  try {
    for (const path of [
      undefined,
      "remote://host/main.admission",
      "wsl://host/main.admission",
      "diff://file/main.admission",
      "agent-conversation://main.admission",
    ]) {
      expect(await resolveEditorLspSupport(path)).toBe(false);
    }
    expect(await resolveEditorLspSupport("C:/fixture/no-owner.admission")).toBe(false);
    expect(isEditorLspSupported("C:/fixture/no-owner.admission")).toBe(false);
    expect(paths).toEqual(["C:/fixture/no-owner.admission"]);
  } finally {
    spy.mockRestore();
  }
});

test("Java and Worker ownership keep their synchronous priority without native probing", async () => {
  const supported = spyOn(extensionRegistry, "isLspSupported").mockReturnValue(true);
  const language = spyOn(extensionRegistry, "getLanguageId").mockReturnValue("worker-fixture");
  const spy = mockNativeInvoke(async () => {
    throw new Error("a known language must not probe declarative ownership");
  });
  try {
    expect(await resolveEditorLspSupport("C:/fixture/Main.java")).toBe(true);
    expect(languageIdForEditorFile("C:/fixture/Main.java")).toBe("java");
    expect(await resolveEditorLspSupport("C:/fixture/Main.workerfixture")).toBe(true);
    expect(languageIdForEditorFile("C:/fixture/Main.workerfixture")).toBe("worker-fixture");
    expect(spy).not.toHaveBeenCalled();
  } finally {
    spy.mockRestore();
    supported.mockRestore();
    language.mockRestore();
  }
});

test("a late ownership answer cannot admit a plugin disabled during its request", async () => {
  setPluginActive(pluginId, true);
  const answer = deferred<typeof owner>();
  const entered = deferred<void>();
  const path = "C:/fixture/late.admission";
  const spy = mockNativeInvoke(async () => {
    entered.resolve();
    return answer.promise;
  });
  const pending = resolveEditorLspSupport(path);
  try {
    await entered.promise;
    setPluginActive(pluginId, false);
    answer.resolve(owner);
    expect(await pending).toBe(false);
    expect(isEditorLspSupported(path)).toBe(false);
    expect(languageIdForEditorFile(path)).toBeUndefined();
  } finally {
    answer.resolve(owner);
    await pending;
    spy.mockRestore();
  }
});

test("revocation invalidates cached hints even while no editor subscribes", async () => {
  setPluginActive(pluginId, true);
  const path = "C:/fixture/cached.admission";
  const spy = spyOn(native, "invoke").mockResolvedValue(owner);
  try {
    expect(await resolveEditorLspSupport(path)).toBe(true);
    setPluginActive(pluginId, false);
    expect(isEditorLspSupported(path)).toBe(false);
    setPluginActive(pluginId, true);
    expect(isEditorLspSupported(path)).toBe(false);
    expect(await resolveEditorLspSupport(path)).toBe(true);
    expect(spy).toHaveBeenCalledTimes(2);
  } finally {
    spy.mockRestore();
  }
});

for (const continuousSubscription of [true, false]) {
  test(`reenabling rejects revoked lookups with ${continuousSubscription ? "an active editor" : "a reopened editor"}`, async () => {
  setPluginActive(pluginId, true);
  const answer = deferred<typeof owner>();
  const entered = deferred<void>();
  let unsubscribe = subscribeDeclarativeLanguageSupport(() => {});
  const path = "C:/fixture/reenable.admission";
  let calls = 0;
  const spy = mockNativeInvoke(async () => {
    if (++calls === 1) {
      entered.resolve();
      return answer.promise;
    }
    return owner;
  });
  const old = resolveEditorLspSupport(path);
  try {
    await entered.promise;
    if (!continuousSubscription) unsubscribe();
    setPluginActive(pluginId, false);
    setPluginActive(pluginId, true);
    if (!continuousSubscription) unsubscribe = subscribeDeclarativeLanguageSupport(() => {});
    expect(await resolveEditorLspSupport(path)).toBe(true);
    answer.resolve(owner);
    expect(await old).toBe(false);
    expect(isEditorLspSupported(path)).toBe(true);
  } finally {
    answer.resolve(owner);
    await old;
    unsubscribe();
    spy.mockRestore();
  }
});
}
