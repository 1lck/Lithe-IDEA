import { describe, expect, mock, test } from "bun:test";
import type { CoreResolveResult, GlobalToolchain } from "../types/run.types";
import { resolveConfigurations } from "./resolve-run-project";

const root = "D:/fixture/project";
const mavenHome = "D:/fixture/apache-maven";
const executable = `${mavenHome}/bin/mvn.cmd`;
const missing = {
  id: "app",
  code: "missingToolchain",
  toolchain: "project-maven",
  message: "No local maven toolchain is selected",
};

function fixture(
  options: {
    selected?: string;
    panel?: string;
    valid?: boolean;
    usesMaven?: boolean;
    version?: string;
  } = {},
) {
  const result: CoreResolveResult = {
    configurations: [
      {
        id: "app",
        name: "App",
        provider: "java.main",
        toolchains: options.usesMaven === false ? {} : { maven: "project-maven" },
      },
    ],
    toolchain: { maven: { executablePath: options.selected ?? "" } },
  };
  const discoverRunToolchains = mock(async (_root: string, selected?: GlobalToolchain) => ({
    java: [],
    runtimes: [],
    maven:
      options.valid !== false && selected?.mavenExecutablePath
        ? [{ executablePath: executable, version: options.version ?? "3.9.9" }]
        : [],
  }));
  const resolveRunConfiguration = mock(
    async (
      _root: string,
      candidates: Array<{ id: string; version: string }>,
    ): Promise<CoreResolveResult> => {
      const maven = candidates.find((candidate) => candidate.id === "project-maven");
      return {
        ...result,
        diagnostics:
          options.usesMaven === false
            ? []
            : !maven
              ? [missing]
              : maven.version === "3.0.0"
                ? [{ ...missing, code: "toolchainVersionMismatch" }]
                : [],
      };
    },
  );
  const mavenLaunchContextForWorkspace = mock(async () => ({
    version: 1 as const,
    skipTests: false,
    reactorPath: ".",
    profiles: [],
    mavenExecutablePath: options.panel ?? mavenHome,
  }));
  return { discoverRunToolchains, resolveRunConfiguration, mavenLaunchContextForWorkspace, formatArgumentTexts: mock(async (lists: string[][]) => lists.map(() => "")) };
}

describe("Run diagnostics use the effective Maven selection", () => {
  test("matches discovered absolute JDK paths to persisted relative selections without changing preferences", async () => {
    const selection: GlobalToolchain = { javaHomePath: "toolchains/JDK 21", mavenExecutablePath: "",
      mavenJavaHomePath: "", runtimeExecutablePaths: { "project-node": "tools/node.exe" } };
    const discoveries: Array<GlobalToolchain | undefined> = [];
    const jdk = { homePath: `${root}/toolchains/JDK 21`, version: "21", vendor: "fixture" };
    const node = { id: "project-node", type: "node", executablePath: `${root}/tools/node.exe`, version: "22", vendor: "fixture" };
    const dependencies = {
      discoverRunToolchains: async (_root: string, selected?: GlobalToolchain) => {
        discoveries.push(selected);
        return { java: selected ? [jdk] : [], maven: [], runtimes: selected ? [node] : [] };
      },
      resolveRunConfiguration: mock(async (_root: string, _candidates: Array<{ id: string; type: string; version: string; vendor: string }>): Promise<CoreResolveResult> => ({
        configurations: [], toolchain: { java: { homePath: selection.javaHomePath } },
        localToolchains: { version: 1, toolchains: { "project-node": { executable: "tools/node.exe" } } },
      })),
      mavenLaunchContextForWorkspace: fixture().mavenLaunchContextForWorkspace,
      formatArgumentTexts: fixture().formatArgumentTexts,
    };
    const resolved = await resolveConfigurations(root, "relative-workspace", dependencies);
    expect(discoveries[1]?.javaHomePath).toBe(jdk.homePath);
    expect(discoveries[1]?.runtimeExecutablePaths["project-node"]).toBe(node.executablePath);
    expect(dependencies.resolveRunConfiguration.mock.calls[1][1]).toEqual([
      { id: "project-jdk", type: "java", version: "21", vendor: "fixture" },
      { id: "project-node", type: "node", version: "22", vendor: "fixture" },
    ]);
    expect(resolved.globalToolchain.javaHomePath).toBe(selection.javaHomePath);
    expect(resolved.effectiveRuntimeExecutablePaths["project-node"]).toBe(node.executablePath);
  });
  test("recognizes a Maven home configured only in the workspace Maven panel", async () => {
    const dependencies = fixture();
    const result = await resolveConfigurations(root, "workspace-A", dependencies);
    expect(result.diagnostics).toEqual([]);
    expect(result.discoveredMaven[0].executablePath).toBe(executable);
    expect(dependencies.mavenLaunchContextForWorkspace).toHaveBeenCalledWith(
      root,
      [],
      "workspace-A",
    );
    // Reading the fallback must not turn it into an explicit Run override.
    expect(result.globalToolchain.mavenExecutablePath).toBe("");
  });

  test("accepts an executable path as well as a Maven home", async () => {
    expect(
      (await resolveConfigurations(root, "workspace-A", fixture({ panel: executable })))
        .diagnostics,
    ).toEqual([]);
  });

  test("keeps an explicit Run selection ahead of the Maven panel", async () => {
    const dependencies = fixture({ selected: mavenHome, panel: "D:/fixture/other-maven" });
    const result = await resolveConfigurations(root, "workspace-A", dependencies);
    expect(result.diagnostics).toEqual([]);
    expect(dependencies.discoverRunToolchains.mock.calls[1][1]?.mavenExecutablePath).toBe(
      mavenHome,
    );
    expect(result.globalToolchain.mavenExecutablePath).toBe(mavenHome);
  });

  test("does not hide a missing executable or incompatible Maven version", async () => {
    const invalid = await resolveConfigurations(root, "workspace-A", fixture({ valid: false }));
    expect(invalid.diagnostics[0].code).toBe("missingToolchain");
    const incompatible = await resolveConfigurations(
      root,
      "workspace-A",
      fixture({ version: "3.0.0" }),
    );
    expect(incompatible.diagnostics[0].code).toBe("toolchainVersionMismatch");
  });

  test("does not load Maven state for projects without Maven consumers", async () => {
    const dependencies = fixture({ usesMaven: false });
    await resolveConfigurations(root, "workspace-A", dependencies);
    expect(dependencies.mavenLaunchContextForWorkspace).not.toHaveBeenCalled();
    expect(dependencies.discoverRunToolchains).toHaveBeenCalledTimes(1);
  });
});

test("run editor preserves argument boundaries from the Core formatter", async () => {
  const dependencies = fixture({ usesMaven: false });
  const resolveRunConfiguration = async (): Promise<CoreResolveResult> => ({
    configurations: [{
      id: "app", name: "App", provider: "shell",
      args: ["--name", "Alice Smith", ""],
    }],
  });
  const formatArgumentTexts = mock(async (lists: string[][]) => {
    expect(lists).toEqual([[], ["--name", "Alice Smith", ""]]);
    return ["", '--name "Alice Smith" ""'];
  });
  const result = await resolveConfigurations(root, "workspace-A", {
    ...dependencies, resolveRunConfiguration, formatArgumentTexts,
  });
  const { runOptionsFor } = await import("../stores/run.store");
  expect(runOptionsFor(result.configurations[0]).programArguments).toBe('--name "Alice Smith" ""');
});
