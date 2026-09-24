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
  return { discoverRunToolchains, resolveRunConfiguration, mavenLaunchContextForWorkspace };
}

describe("Run diagnostics use the effective Maven selection", () => {
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
