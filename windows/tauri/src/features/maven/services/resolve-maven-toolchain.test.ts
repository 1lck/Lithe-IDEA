import { expect, mock, test } from "bun:test";
import type { MavenToolchainDependencies } from "./resolve-maven-toolchain";
import { resolveEffectiveMavenExecutable } from "./resolve-maven-toolchain";

const ROOT = "D:/workspace/demo";

function dependencies(overrides: Partial<MavenToolchainDependencies> = {}) {
  const resolveRunConfiguration = mock(async () => ({
    configurations: [],
    toolchain: { maven: { executablePath: "" } },
  }));
  const discoverRunToolchains = mock(async () => ({
    java: [],
    maven: [] as Array<{ executablePath: string; version: string }>,
    runtimes: [],
  }));
  return {
    resolveRunConfiguration,
    discoverRunToolchains,
    ...overrides,
  } as unknown as MavenToolchainDependencies & {
    resolveRunConfiguration: ReturnType<typeof mock>;
    discoverRunToolchains: ReturnType<typeof mock>;
  };
}

test("an explicit Maven path wins without probing the host", async () => {
  const injected = dependencies();

  const resolved = await resolveEffectiveMavenExecutable(
    ROOT,
    "  D:/apache-maven-3.9.16  ",
    injected,
  );

  expect(resolved).toBe("D:/apache-maven-3.9.16");
  // A configured workspace must not pay for `mvn -version` probes on every load.
  expect(injected.resolveRunConfiguration).not.toHaveBeenCalled();
  expect(injected.discoverRunToolchains).not.toHaveBeenCalled();
});

test("an empty Maven panel falls back to the Run configuration toolchain", async () => {
  const injected = dependencies({
    resolveRunConfiguration: mock(async () => ({
      configurations: [],
      toolchain: { maven: { executablePath: "D:/apache-maven-3.9.16/bin/mvn.cmd" } },
    })),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  expect(resolved).toBe("D:/apache-maven-3.9.16/bin/mvn.cmd");
  expect(injected.discoverRunToolchains).not.toHaveBeenCalled();
});

test("host discovery supplies the Maven when neither setting is filled in", async () => {
  const injected = dependencies({
    discoverRunToolchains: mock(async () => ({
      java: [],
      maven: [
        { executablePath: "D:/workspace/demo/mvnw.cmd", version: "3.9.16" },
        { executablePath: "C:/tools/maven/bin/mvn.cmd", version: "3.9.16" },
      ],
      runtimes: [],
    })),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  // Discovery reports the wrapper first, matching what a build would run.
  expect(resolved).toBe("D:/workspace/demo/mvnw.cmd");
});

test("a failing Run resolution still reaches host discovery", async () => {
  const injected = dependencies({
    resolveRunConfiguration: mock(async () => {
      throw new Error("run documents are missing");
    }),
    discoverRunToolchains: mock(async () => ({
      java: [],
      maven: [{ executablePath: "C:/tools/maven/bin/mvn.cmd", version: "3.9.16" }],
      runtimes: [],
    })),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  expect(resolved).toBe("C:/tools/maven/bin/mvn.cmd");
});

test("no Maven anywhere resolves to an empty selection instead of failing", async () => {
  const injected = dependencies({
    discoverRunToolchains: mock(async () => {
      throw new Error("discovery is unavailable");
    }),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  // Import must continue on the JDT LS defaults rather than block the project.
  expect(resolved).toBe("");
});
