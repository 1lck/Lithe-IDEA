import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import { createJSONStorage } from "zustand/middleware";
import {
  evaluateWhenClause,
  prepareWhenClause,
  prepareKeymapContexts,
  releasePreparedContexts,
} from "./context";
import { parseKeybindingsImportJson } from "./keybinding-import-export";

const restoreDom = installHappyDom();
const { useKeymapStore } = await import("../stores/keymaps.store");
const previousStorage = useKeymapStore.persist.getOptions().storage;
afterAll(() => {
  useKeymapStore.persist.setOptions({ storage: previousStorage });
  restoreDom();
});
let previous: ReturnType<typeof useKeymapStore.getState>;
beforeEach(() => {
  useKeymapStore.persist.setOptions({ storage: createJSONStorage(() => window.localStorage) });
  previous = useKeymapStore.getState();
  useKeymapStore.getState().actions.resetToDefaults();
  releasePreparedContexts();
});
afterEach(() => {
  useKeymapStore.setState(previous);
  releasePreparedContexts();
});
const binding = (when?: string) => ({
  key: "ctrl+k",
  command: "test.action",
  source: "user" as const,
  when,
});
const focused = { keys: ["editorFocus"], values: [false, true] };

test("keydown projects only precompiled Core outcomes and never invokes or parses source", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({ parsed: focused, error: null });
  try {
    expect(evaluateWhenClause("@", {})).toBe(false);
    expect(evaluateWhenClause(undefined, {})).toBe(true);
    expect(invoke).not.toHaveBeenCalled();
    await prepareWhenClause("editorFocus");
    invoke.mockClear();
    for (let index = 0; index < 1000; index++) {
      expect(evaluateWhenClause("editorFocus", { editorFocus: index % 2 === 0 })).toBe(
        index % 2 === 0,
      );
    }
    expect(invoke).not.toHaveBeenCalled();
  } finally {
    invoke.mockRestore();
  }
});

test("the same expression shares Core compilation across bindings", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({ parsed: focused, error: null });
  try {
    await Promise.all([prepareWhenClause("editorFocus"), prepareWhenClause("editorFocus")]);
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke.mock.calls[0]).toEqual(["keymap.parseContext", { expression: "editorFocus" }]);
  } finally {
    invoke.mockRestore();
  }
});

test("invalid import rejects the whole batch before store or persisted state changes", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({
    parsed: null,
    error: { code: "invalid_character", byteOffset: 0 },
  });
  try {
    const before = useKeymapStore.getState().keybindings;
    const storage = window.localStorage.getItem("keymaps-storage");
    await expect(
      parseKeybindingsImportJson(JSON.stringify([binding(), binding("@")])),
    ).rejects.toMatchObject({ code: "invalid_character" });
    expect(useKeymapStore.getState().keybindings).toBe(before);
    expect(window.localStorage.getItem("keymaps-storage")).toBe(storage);
  } finally {
    invoke.mockRestore();
  }
});

test("valid import retains preset, disabled state and arguments after Core validation", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({ parsed: focused, error: null });
  try {
    const item = { ...binding("editorFocus"), enabled: false, args: { text: "中文😀" } };
    const imported = await parseKeybindingsImportJson(
      JSON.stringify({
        format: "lithe.keybindings",
        version: 1,
        keybindingPreset: "none",
        keybindings: [item],
      }),
    );
    expect(imported?.keybindingPreset).toBe("none");
    expect(imported?.keybindings[0]).toMatchObject(item);
  } finally {
    invoke.mockRestore();
  }
});

test("failed imports do not consume the active context cache", async () => {
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
    const expression = (args as { expression: string }).expression;
    return (expression === "@"
      ? { parsed: null, error: { code: "invalid_character", byteOffset: 0 } }
      : { parsed: focused, error: null }) as T;
  });
  try {
    await prepareWhenClause("active");
    const oversized = Array.from({ length: 257 }, (_, index) => binding(`key${index}`));
    await expect(parseKeybindingsImportJson(JSON.stringify(oversized))).rejects.toMatchObject({ code: "too_many_conditions" });
    await expect(parseKeybindingsImportJson(JSON.stringify([binding("candidate"), binding("@")]))).rejects.toMatchObject({ code: "invalid_character" });
    expect(evaluateWhenClause("active", { editorFocus: true })).toBe(true);
    expect(evaluateWhenClause("candidate", { editorFocus: true })).toBe(false);
    await expect(parseKeybindingsImportJson(JSON.stringify([binding("newCondition")]))).resolves.not.toBeNull();
    expect(evaluateWhenClause("newCondition", { editorFocus: true })).toBe(true);
  } finally {
    invoke.mockRestore();
  }
});

test("add and update reject invalid conditions without replacing a saved binding", async () => {
  await useKeymapStore.getState().actions.addKeybinding(binding());
  const before = useKeymapStore.getState().keybindings;
  const storage = window.localStorage.getItem("keymaps-storage");
  expect(JSON.parse(storage!).state.keybindings[0].command).toBe("test.action");
  const invoke = spyOn(native, "invoke").mockResolvedValue({
    parsed: null,
    error: { code: "expected_operand", byteOffset: 13 },
  });
  try {
    await expect(
      useKeymapStore.getState().actions.updateKeybinding("test.action", { when: "editorFocus &&" }),
    ).rejects.toMatchObject({ code: "expected_operand" });
    await expect(
      useKeymapStore.getState().actions.addKeybinding(binding("!")),
    ).rejects.toMatchObject({ code: "expected_operand" });
    expect(useKeymapStore.getState().keybindings).toBe(before);
    expect(window.localStorage.getItem("keymaps-storage")).toBe(storage);
  } finally {
    invoke.mockRestore();
  }
});

test("prepared-context memory and concurrent requests have a fixed window limit", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue({ parsed: focused, error: null });
  try {
    for (let index = 0; index < 256; index++) await prepareWhenClause(`key${index}`);
    await expect(prepareWhenClause("overflow")).rejects.toMatchObject({
      code: "too_many_conditions",
    });
    expect(invoke).toHaveBeenCalledTimes(256);
    releasePreparedContexts();
    await prepareWhenClause("overflow");
    expect(invoke).toHaveBeenCalledTimes(257);
  } finally {
    invoke.mockRestore();
  }
});

test("retired configurations cannot create an unbounded native request backlog", async () => {
  let release!: (value: unknown) => void;
  const response = new Promise((resolve) => {
    release = resolve;
  });
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T>(): Promise<T> => (await response) as T,
  );
  const requests: Promise<void>[] = [];
  try {
    for (let index = 0; index < 16; index++) {
      requests.push(prepareWhenClause(`pending${index}`));
      releasePreparedContexts();
    }
    await expect(prepareWhenClause("overflow")).rejects.toMatchObject({ code: "preparation_busy" });
    expect(invoke).toHaveBeenCalledTimes(16);
  } finally {
    release({ parsed: focused, error: null });
    await Promise.all(requests);
    invoke.mockRestore();
  }
});

test("reset while Core validates an addition cannot resurrect the old configuration", async () => {
  let release!: (value: unknown) => void;
  const response = new Promise((resolve) => {
    release = resolve;
  });
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T>(): Promise<T> => (await response) as T,
  );
  const addition = useKeymapStore.getState().actions.addKeybinding(binding("editorFocus"));
  try {
    useKeymapStore.getState().actions.resetToDefaults();
    release({ parsed: focused, error: null });
    await expect(addition).rejects.toMatchObject({ code: "configuration_changed" });
    expect(useKeymapStore.getState().keybindings).toEqual([]);
  } finally {
    release({ parsed: focused, error: null });
    await addition.catch(() => {});
    invoke.mockRestore();
  }
});

test("failed native compilation can be retried without keeping a broken cache entry", async () => {
  const invoke = spyOn(native, "invoke")
    .mockRejectedValueOnce(new Error("host unavailable"))
    .mockResolvedValueOnce({ parsed: focused, error: null });
  try {
    await expect(prepareWhenClause("editorFocus")).rejects.toThrow("host unavailable");
    expect(evaluateWhenClause("editorFocus", { editorFocus: true })).toBe(false);
    await prepareWhenClause("editorFocus");
    expect(evaluateWhenClause("editorFocus", { editorFocus: true })).toBe(true);
  } finally {
    invoke.mockRestore();
  }
});

test("retired preparations do not compile additional expressions after owner teardown", async () => {
  let release!: (value: unknown) => void;
  const response = new Promise((resolve) => {
    release = resolve;
  });
  const invoke = spyOn(native, "invoke").mockImplementation(
    async <T>(): Promise<T> => (await response) as T,
  );
  const controller = new AbortController();
  const preparation = prepareKeymapContexts(
    [binding("editorFocus"), binding("terminalFocus")],
    controller.signal,
  );
  try {
    controller.abort();
    releasePreparedContexts();
    release({ parsed: focused, error: null });
    await preparation;
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(evaluateWhenClause("editorFocus", { editorFocus: true })).toBe(false);
  } finally {
    release({ parsed: focused, error: null });
    await preparation;
    invoke.mockRestore();
  }
});
