import { describe, expect, test } from "bun:test";
import {
  clearUpdatePreferencesForNewVersion,
  readUpdatePreferences,
  remindAboutUpdateLater,
  shouldSuppressUpdate,
  skipUpdateVersion,
  writeUpdatePreferences,
  type UpdatePreferenceTarget,
} from "./update-preferences";

class MemoryStorage {
  private readonly values = new Map<string, string>();

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }

  removeItem(key: string) {
    this.values.delete(key);
  }
}

const update: UpdatePreferenceTarget = { version: "0.3.1" };

describe("update preferences", () => {
  test("reminds for 24 hours and suppresses only the exact target version", () => {
    const storage = new MemoryStorage();
    const now = 1_800_000_000_000;

    remindAboutUpdateLater(update, now, 24 * 60 * 60 * 1000, storage);

    expect(shouldSuppressUpdate(update, now + 1, readUpdatePreferences(storage))).toBe(true);
    expect(
      shouldSuppressUpdate({ version: "0.3.2" }, now + 1, readUpdatePreferences(storage)),
    ).toBe(false);
    expect(
      shouldSuppressUpdate(update, now + 24 * 60 * 60 * 1000, readUpdatePreferences(storage)),
    ).toBe(false);
  });

  test("skip version remains suppressed until a newer version is checked", () => {
    const storage = new MemoryStorage();

    skipUpdateVersion(update, storage);

    expect(shouldSuppressUpdate(update, 1_800_000_000_000, readUpdatePreferences(storage))).toBe(
      true,
    );
    clearUpdatePreferencesForNewVersion({ version: "0.3.2" }, storage);
    expect(readUpdatePreferences(storage)).toEqual({});
  });

  test("later preference clears a previous skipped version", () => {
    const storage = new MemoryStorage();
    writeUpdatePreferences({ skippedVersion: "0.3.1" }, storage);

    remindAboutUpdateLater(update, 1_800_000_000_000, 60_000, storage);

    expect(readUpdatePreferences(storage)).toEqual({
      remindVersion: "0.3.1",
      remindAfter: 1_800_000_060_000,
    });
  });
});
