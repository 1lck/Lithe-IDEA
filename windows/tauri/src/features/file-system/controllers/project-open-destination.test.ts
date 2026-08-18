import { describe, expect, test } from "bun:test";
import { defaultSettings } from "@/features/settings/config/default-settings";
import {
  chooseProjectOpenDestination,
  executeProjectOpenDecision,
  hasOpenProjectWorkspace,
  type ProjectOpenDestination,
  type ProjectOpenDestinationServices,
  type ProjectOpenPromptResult,
} from "./project-open-destination";

function createServices(options?: {
  askWhereToOpenProjects?: boolean;
  openFoldersInNewWindow?: boolean;
  promptResult?: ProjectOpenPromptResult | null;
  language?: "en-US" | "zh-CN";
}) {
  const promptRequests: Array<{ projectName: string; language: "en-US" | "zh-CN" }> = [];
  const updates: Array<[string, boolean]> = [];

  const services: ProjectOpenDestinationServices = {
    getSettings: () => ({
      askWhereToOpenProjects: options?.askWhereToOpenProjects ?? true,
      openFoldersInNewWindow: options?.openFoldersInNewWindow ?? true,
      displayLanguage: options?.language ?? "en-US",
    }),
    prompt: async (request) => {
      promptRequests.push(request);
      return options?.promptResult ?? null;
    },
    updateSetting: async (key, value) => {
      updates.push([key, value]);
    },
  };

  return { services, promptRequests, updates };
}

describe("project open destination", () => {
  test("asks where to open projects by default", () => {
    expect(defaultSettings.askWhereToOpenProjects).toBe(true);
  });

  test("opens directly in this window when no workspace is open", async () => {
    const { services, promptRequests } = createServices();

    const decision = await chooseProjectOpenDestination(
      { projectName: "Lithe", hasOpenWorkspace: false },
      services,
    );

    expect(decision).toEqual({ destination: "this-window", rememberAfterOpen: false });
    expect(promptRequests).toEqual([]);
  });

  test.each([
    [true, "new-window"],
    [false, "this-window"],
  ] as const)("uses the remembered destination when prompting is disabled", async (openNew, expected) => {
    const { services, promptRequests } = createServices({
      askWhereToOpenProjects: false,
      openFoldersInNewWindow: openNew,
    });

    const decision = await chooseProjectOpenDestination(
      { projectName: "Lithe", hasOpenWorkspace: true },
      services,
    );

    expect(decision).toEqual({ destination: expected, rememberAfterOpen: false });
    expect(promptRequests).toEqual([]);
  });

  test("returns an unchecked selection without changing settings", async () => {
    const selected: ProjectOpenDestination = "new-window";
    const { services, promptRequests, updates } = createServices({
      language: "zh-CN",
      promptResult: { destination: selected, doNotAskAgain: false },
    });

    const decision = await chooseProjectOpenDestination(
      { projectName: "Lithe", hasOpenWorkspace: true },
      services,
    );

    expect(decision).toEqual({ destination: selected, rememberAfterOpen: false });
    expect(promptRequests).toEqual([{ projectName: "Lithe", language: "zh-CN" }]);
    expect(updates).toEqual([]);
  });

  test.each(["new-window", "this-window"] as const)(
    "defers a checked destination until the project opens",
    async (selected) => {
      const { services, updates } = createServices({
        promptResult: { destination: selected, doNotAskAgain: true },
      });

      const decision = await chooseProjectOpenDestination(
        { projectName: "Lithe", hasOpenWorkspace: true },
        services,
      );

      expect(decision).toEqual({ destination: selected, rememberAfterOpen: true });
      expect(updates).toEqual([]);
    },
  );

  test("cancels without opening or changing settings", async () => {
    const { services, updates } = createServices({ promptResult: null });

    const decision = await chooseProjectOpenDestination(
      { projectName: "Lithe", hasOpenWorkspace: true },
      services,
    );

    expect(decision).toBeNull();
    expect(updates).toEqual([]);
  });

  test("uses an explicit destination without prompting or remembering", async () => {
    const { services, promptRequests, updates } = createServices({
      promptResult: { destination: "new-window", doNotAskAgain: true },
    });

    const decision = await chooseProjectOpenDestination(
      {
        projectName: "Lithe",
        hasOpenWorkspace: true,
        explicitDestination: "this-window",
      },
      services,
    );

    expect(decision).toEqual({ destination: "this-window", rememberAfterOpen: false });
    expect(promptRequests).toEqual([]);
    expect(updates).toEqual([]);
  });

  test("persists a checked destination only after a successful open", async () => {
    const { services, updates } = createServices();
    const events: string[] = [];
    const recordingServices: ProjectOpenDestinationServices = {
      ...services,
      updateSetting: async (key, value) => {
        events.push(`setting:${key}:${value}`);
        updates.push([key, value]);
      },
    };

    const opened = await executeProjectOpenDecision(
      { destination: "new-window", rememberAfterOpen: true },
      async (destination) => {
        events.push(`open:${destination}`);
        return true;
      },
      recordingServices,
    );

    expect(opened).toBe(true);
    expect(events).toEqual([
      "open:new-window",
      "setting:openFoldersInNewWindow:true",
      "setting:askWhereToOpenProjects:false",
    ]);
  });

  test.each([false, "throw"] as const)(
    "does not persist a checked destination when opening fails",
    async (failureMode) => {
      const { services, updates } = createServices();
      const execute = () =>
        executeProjectOpenDecision(
          { destination: "this-window", rememberAfterOpen: true },
          async () => {
            if (failureMode === "throw") throw new Error("open failed");
            return false;
          },
          services,
        );

      if (failureMode === "throw") {
        await expect(execute()).rejects.toThrow("open failed");
      } else {
        expect(await execute()).toBe(false);
      }
      expect(updates).toEqual([]);
    },
  );

  test("treats an existing project tab as an open workspace during initialization", () => {
    expect(
      hasOpenProjectWorkspace({
        rootFolderPath: undefined,
        fileCount: 0,
        projectTabCount: 1,
      }),
    ).toBe(true);
    expect(
      hasOpenProjectWorkspace({
        rootFolderPath: undefined,
        fileCount: 0,
        projectTabCount: 0,
      }),
    ).toBe(false);
  });
});
