import { describe, expect, mock, test } from "bun:test";
import type { RunConfiguration } from "../types/run.types";
import { editJavaMainConfiguration, javaMainConfiguration } from "./java-main-launch";

function configuration(overrides: Partial<RunConfiguration>): RunConfiguration {
  return {
    id: "generated-app",
    name: "App",
    provider: "java.main",
    kindTitle: "Application",
    execution: "application",
    category: "project",
    mainClass: "demo.App",
    sourcePath: "src/main/java/demo/App.java",
    cwd: ".",
    args: [],
    env: {},
    jvmArguments: [],
    programArguments: [],
    profiles: [],
    mavenSkipTests: null,
    javaHomePath: "",
    mavenExecutablePath: "",
    mavenJavaHomePath: "",
    toolchains: {},
    source: "generated",
    disabled: false,
    ...overrides,
  };
}

describe("configuration for a main marker", () => {
  test("editing a main marker selects its settings form before opening Settings", async () => {
    const calls: string[] = [];
    const resolve = mock(async () => configuration({ id: "service-a" }));
    await editJavaMainConfiguration("workspace-a", "src/App.java", "demo.App", {
      resolve,
      edit: (workspace, id) => {
        calls.push(`${workspace}:${id}`);
      },
      openSettings: () => {
        calls.push("settings");
      },
    });
    expect(resolve).toHaveBeenCalledWith("workspace-a", "src/App.java", "demo.App");
    expect(calls).toEqual(["workspace-a:service-a", "settings"]);
  });

  test("failed main resolution does not open an unrelated settings form", async () => {
    const edit = mock(() => {});
    const openSettings = mock(() => {});
    await expect(
      editJavaMainConfiguration("workspace-a", "src/App.java", "demo.App", {
        resolve: async () => {
          throw new Error("No configuration");
        },
        edit,
        openSettings,
      }),
    ).rejects.toThrow("No configuration");
    expect(edit).not.toHaveBeenCalled();
    expect(openSettings).not.toHaveBeenCalled();
  });

  const sourcePath = "src/main/java/demo/App.java";

  test("matches both the class and the source file", () => {
    const configurations = [
      configuration({ id: "other-module", sourcePath: "other/src/main/java/demo/App.java" }),
      configuration({ id: "generated-app" }),
    ];
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.App")?.id).toBe(
      "generated-app",
    );
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.Other")).toBeNull();
  });

  test("reuses an edited copy over the generated entry, and the selection over both", () => {
    const configurations = [
      configuration({ id: "generated-app" }),
      configuration({ id: "local-app", source: "local" }),
      configuration({ id: "project-app", source: "project" }),
    ];
    expect(javaMainConfiguration(configurations, null, sourcePath, "demo.App")?.id).toBe(
      "local-app",
    );
    expect(javaMainConfiguration(configurations, "generated-app", sourcePath, "demo.App")?.id).toBe(
      "generated-app",
    );
  });

  test("never picks a disabled configuration", () => {
    expect(
      javaMainConfiguration(
        [configuration({ id: "disabled", disabled: true })],
        "disabled",
        sourcePath,
        "demo.App",
      ),
    ).toBeNull();
  });
});

describe("on-demand Java main configuration", () => {
  const root = "D:/projects/plain";
  const source = `${root}/Test.java`;
  async function harness() {
    const { resolveMainConfiguration } = await import("./java-main-launch");
    const { createRunStore } = await import("../stores/run.store");
    const store = createRunStore("test-workspace");
    store.setState({ root, configurations: [] });
    const calls: string[] = [];
    const generate = mock(
      async (_root: string, entry?: { sourcePath: string; mainClass: string }) => {
        calls.push("generate");
        store.setState({
          configurations: [
            configuration({
              id: "test-main",
              sourcePath: entry?.sourcePath,
              mainClass: entry?.mainClass,
            }),
          ],
        });
      },
    );
    store.setState({ actions: { ...store.getState().actions, generate } });
    const dependencies = {
      runStore: () => store,
      fileStore: () => {
        throw new Error("workspace root already known");
      },
      save: mock(async () => {
        calls.push("save");
      }),
      prepare: mock(async () => {
        calls.push("prepare");
        return { kind: "ready" as const };
      }),
      mainMethods: mock(async () => {
        calls.push("JDT file main");
        return {
          schemaVersion: 1 as const,
          diagnostics: [],
          methods: [
            {
              mainClass: "Test",
              projectName: "default",
              range: { startLine: 1, endLine: 1, startUtf16Column: 0, endUtf16Column: 4 },
            },
          ],
        };
      }),
    };
    return {
      store,
      calls,
      generate,
      dependencies,
      resolve: () => resolveMainConfiguration("test-workspace", source, "Test", dependencies),
    };
  }

  test("saves then prepares JDT and creates a config for the exact unmanaged file", async () => {
    const h = await harness();
    expect((await h.resolve()).id).toBe("test-main");
    expect(h.calls).toEqual(["save", "prepare", "JDT file main", "generate"]);
    expect(h.generate).toHaveBeenCalledWith(root, {
      sourcePath: "Test.java",
      mainClass: "Test",
      projectName: "default",
    });
  });
  test("a failed save does not query JDT or create a configuration", async () => {
    const h = await harness();
    h.dependencies.save.mockImplementation(async () => {
      throw new Error("save conflict");
    });
    await expect(h.resolve()).rejects.toThrow("save conflict");
    expect(h.generate).not.toHaveBeenCalled();
    expect(h.dependencies.prepare).not.toHaveBeenCalled();
  });
  test("a stale editor marker cannot invent a runnable Java class", async () => {
    const h = await harness();
    h.dependencies.mainMethods.mockImplementation(async () => ({
      schemaVersion: 1,
      methods: [],
      diagnostics: [],
    }));
    await expect(h.resolve()).rejects.toThrow("no longer reports");
    expect(h.generate).not.toHaveBeenCalled();
  });
  test("switching workspace during JDT resolution prevents publication", async () => {
    const h = await harness();
    const answer = await h.dependencies.mainMethods();
    h.dependencies.mainMethods.mockImplementation(async () => {
      h.store.setState({ root: "D:/other" });
      return answer;
    });
    await expect(h.resolve()).rejects.toThrow("workspace changed");
    expect(h.generate).not.toHaveBeenCalled();
  });
  test("matches Windows source casing without confusing modules", () => {
    expect(
      javaMainConfiguration(
        [configuration({ sourcePath: "SRC\\DEMO\\App.java" })],
        null,
        "src/demo/App.java",
        "demo.App",
      )?.id,
    ).toBe("generated-app");
  });
});
