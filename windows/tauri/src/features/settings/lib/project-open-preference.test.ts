import { describe, expect, test } from "bun:test";
import {
  getProjectOpenPreference,
  getProjectOpenPreferencePatch,
} from "./project-open-preference";

describe("project open preference", () => {
  test("maps persisted settings to all four visible modes", () => {
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: true,
        projectOpenDefaultDestination: "new-window",
      }),
    ).toBe("ask");
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: false,
        projectOpenDefaultDestination: "this-window",
      }),
    ).toBe("this-window");
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: false,
        projectOpenDefaultDestination: "new-window",
      }),
    ).toBe("new-window");
    expect(
      getProjectOpenPreference({
        askWhereToOpenProjects: false,
        projectOpenDefaultDestination: "attach",
      }),
    ).toBe("attach");
  });

  test("keeps the remembered destination when ask mode is selected", () => {
    expect(getProjectOpenPreferencePatch("ask")).toEqual({
      askWhereToOpenProjects: true,
    });
  });

  test.each([
    ["this-window"],
    ["new-window"],
    ["attach"],
  ] as const)("disables asking for an explicit destination: %s", (preference) => {
    expect(getProjectOpenPreferencePatch(preference)).toEqual({
      askWhereToOpenProjects: false,
      projectOpenDefaultDestination: preference,
    });
  });
});
