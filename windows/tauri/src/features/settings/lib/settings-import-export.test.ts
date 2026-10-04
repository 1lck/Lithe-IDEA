import { describe, expect, test } from "bun:test";
import { parseSettingsImportJson } from "./settings-import-export";

describe("settings import project open destination", () => {
  test.each([
    [true, "new-window"],
    [false, "attach"],
  ] as const)(
    "derives %s from a legacy openFoldersInNewWindow export",
    (legacyValue, expected) => {
      const imported = parseSettingsImportJson(
        JSON.stringify({ wordWrap: false, openFoldersInNewWindow: legacyValue }),
      );

      expect(imported).not.toBeNull();
      expect(imported?.projectOpenDefaultDestination).toBe(expected);
      expect("openFoldersInNewWindow" in (imported ?? {})).toBe(false);
    },
  );

  test("keeps an explicit destination over the legacy boolean", () => {
    const imported = parseSettingsImportJson(
      JSON.stringify({
        openFoldersInNewWindow: true,
        projectOpenDefaultDestination: "attach",
      }),
    );

    expect(imported?.projectOpenDefaultDestination).toBe("attach");
  });
});
