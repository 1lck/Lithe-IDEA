import { describe, expect, test } from "bun:test";
import {
  getProjectOpenPreference,
  getProjectOpenPreferencePatch,
} from "./project-open-preference";

describe("project open preference", () => {
  test("maps persisted settings to all three visible modes", () => {
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: true,
        openFoldersInNewWindow: true,
      }),
    ).toBe("ask");
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: false,
        openFoldersInNewWindow: false,
      }),
    ).toBe("this-window");
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: false,
        openFoldersInNewWindow: true,
      }),
    ).toBe("new-window");
  });

  test("keeps the remembered destination when ask mode is selected", () => {
    expect(getProjectOpenPreferencePatch("ask")).toEqual({
      askWhereToOpenProjects: true,
    });
  });

  test.each([
    ["this-window", false],
    ["new-window", true],
  ] as const)("disables asking for an explicit destination", (preference, openNew) => {
    expect(getProjectOpenPreferencePatch(preference)).toEqual({
      askWhereToOpenProjects: false,
      openFoldersInNewWindow: openNew,
    });
  });
});
