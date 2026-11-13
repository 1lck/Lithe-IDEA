import { expect, spyOn, test } from "bun:test";
import * as pluginStore from "@tauri-apps/plugin-store";
import { defaultSettings } from "../config/default-settings";
import { loadSettingsFromStore, saveJavaImportTimeoutPreference } from "./settings-persistence";

test("explicit timeout saves persist, reset deletes the override, and failed saves restore the previous value", async () => {
  const values = new Map<string, unknown>(Object.entries(defaultSettings));
  let persisted = new Map(values);
  let failSave = false;
  const load = spyOn(pluginStore, "load").mockResolvedValue({
    entries: async () => [...values.entries()],
    get: async (key: string) => values.get(key),
    set: async (key: string, value: unknown) => {
      values.set(key, value);
    },
    delete: async (key: string) => values.delete(key),
    onKeyChange: async () => () => {},
    save: async () => {
      if (failSave) throw new Error("disk full");
      persisted = new Map(values);
    },
  } as never);
  try {
    await loadSettingsFromStore();
    await saveJavaImportTimeoutPreference(60);
    expect(persisted.get("javaImportTimeoutMinutes")).toBe(60);
    expect((await loadSettingsFromStore()).javaImportTimeoutMinutes).toBe(60);
    failSave = true;
    await expect(saveJavaImportTimeoutPreference(90)).rejects.toThrow("disk full");
    expect(values.get("javaImportTimeoutMinutes")).toBe(60);
    expect(persisted.get("javaImportTimeoutMinutes")).toBe(60);
    failSave = false;
    await saveJavaImportTimeoutPreference(undefined);
    expect(persisted.has("javaImportTimeoutMinutes")).toBe(false);
    expect((await loadSettingsFromStore()).javaImportTimeoutMinutes).toBeUndefined();
  } finally {
    load.mockRestore();
  }
}, 5_000);
