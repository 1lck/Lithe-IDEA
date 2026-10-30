import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  IndexingSettingsError,
  indexingSettingsStorageKey,
  readIndexingSettings,
  writeIndexingSettings,
} from "./workspace-indexing";

let restore: () => void;
beforeEach(() => {
  restore = installHappyDom();
});
afterEach(() => restore());

test.each([
  "",
  "broken",
  "null",
  "[]",
  "{}",
  '{"gitIgnoreEnabled":true,"includedDirectories":[1]}',
  '{"gitIgnoreEnabled":true,"includedDirectories":[],"previousRoles":null}',
  '{"gitIgnoreEnabled":true,"includedDirectories":[],"previousRoles":{"src":1}}',
])("invalid indexing settings are classified and preserved: %s", (raw) => {
  const key = indexingSettingsStorageKey("C:/fixture");
  window.localStorage.setItem(key, raw);
  expect(() => readIndexingSettings("C:/fixture")).toThrow(IndexingSettingsError);
  try {
    readIndexingSettings("C:/fixture");
  } catch (cause) {
    expect((cause as IndexingSettingsError).code).toBe("invalidSettings");
  }
  expect(window.localStorage.getItem(key)).toBe(raw);
});

test("storage failures expose stable codes and preserve the saved preference", () => {
  const settings = { gitIgnoreEnabled: false, includedDirectories: ["keep"], previousRoles: {} };
  writeIndexingSettings("C:/fixture", settings);
  const descriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
  const storage = window.localStorage;
  let failRead = true;
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: {
      getItem: (key: string) => {
        if (failRead) throw new Error("fixture read");
        return storage.getItem(key);
      },
      setItem: () => {
        throw new Error("fixture quota");
      },
    },
  });
  try {
    expect(() => readIndexingSettings("C:/fixture")).toThrow("readFailed");
    failRead = false;
    expect(() =>
      writeIndexingSettings("C:/fixture", { ...settings, gitIgnoreEnabled: true }),
    ).toThrow("writeFailed");
  } finally {
    if (descriptor) Object.defineProperty(window, "localStorage", descriptor);
    else Reflect.deleteProperty(window, "localStorage");
  }
  expect(readIndexingSettings("C:/fixture")).toEqual(settings);
});
