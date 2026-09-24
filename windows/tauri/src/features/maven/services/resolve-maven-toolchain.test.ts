import { expect, mock, test } from "bun:test";
import type { MavenToolchainDependencies } from "./resolve-maven-toolchain";
import { resolveEffectiveMavenExecutable } from "./resolve-maven-toolchain";

const ROOT = "D:/workspace/demo";

function dependencies(overrides: Partial<MavenToolchainDependencies> = {}) {
  const inspectRunConfiguration = mock(async () => ({
    status: "missing",
    toolchain: { maven: { executablePath: "" } },
  }));
  const resolveMavenInstallation = mock(async () => null);
  return {
    inspectRunConfiguration,
    resolveMavenInstallation,
    ...overrides,
  } as unknown as MavenToolchainDependencies & {
    inspectRunConfiguration: ReturnType<typeof mock>;
    resolveMavenInstallation: ReturnType<typeof mock>;
  };
}

test("an explicit Maven path wins without consulting the host", async () => {
  const injected = dependencies();

  const resolved = await resolveEffectiveMavenExecutable(
    ROOT,
    "  D:/apache-maven-3.9.16  ",
    injected,
  );

  expect(resolved).toBe("D:/apache-maven-3.9.16");
  expect(injected.inspectRunConfiguration).not.toHaveBeenCalled();
  expect(injected.resolveMavenInstallation).not.toHaveBeenCalled();
});

test("project Maven is honored before run configurations are generated", async () => {
  const injected = dependencies({
    inspectRunConfiguration: mock(async () => ({
      status: "missing",
      toolchain: { maven: { executablePath: "D:/apache-maven-3.9.16" } },
    })),
    resolveMavenInstallation: mock(async () => "D:/apache-maven-3.9.16/bin/mvn.cmd"),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  // The host normalizes a Maven home into the launcher a build would run.
  expect(injected.inspectRunConfiguration).toHaveBeenCalledWith(ROOT, false);
  expect(injected.resolveMavenInstallation).toHaveBeenCalledWith(
    ROOT,
    "D:/apache-maven-3.9.16",
  );
  expect(resolved).toBe("D:/apache-maven-3.9.16/bin/mvn.cmd");
});

test("an unconfigured workspace falls back to the host's own candidate order", async () => {
  const injected = dependencies({
    resolveMavenInstallation: mock(async () => "D:/workspace/demo/mvnw.cmd"),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  expect(injected.resolveMavenInstallation).toHaveBeenCalledWith(ROOT, undefined);
  // A wrapper wins over a machine installation, matching what a build runs.
  expect(resolved).toBe("D:/workspace/demo/mvnw.cmd");
});

test("a failing Run resolution still reaches host resolution", async () => {
  const injected = dependencies({
    inspectRunConfiguration: mock(async () => {
      throw new Error("run documents are missing");
    }),
    resolveMavenInstallation: mock(async () => "C:/tools/maven/bin/mvn.cmd"),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  expect(resolved).toBe("C:/tools/maven/bin/mvn.cmd");
});

test("a failing host resolution keeps the Run configuration selection", async () => {
  const injected = dependencies({
    inspectRunConfiguration: mock(async () => ({
      status: "missing",
      toolchain: { maven: { executablePath: "D:/apache-maven-3.9.16" } },
    })),
    resolveMavenInstallation: mock(async () => {
      throw new Error("host command is unavailable");
    }),
  } as Partial<MavenToolchainDependencies>);

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  expect(resolved).toBe("D:/apache-maven-3.9.16");
});

test("no Maven anywhere resolves to an empty selection instead of failing", async () => {
  const injected = dependencies();

  const resolved = await resolveEffectiveMavenExecutable(ROOT, "", injected);

  // Import must continue on the JDT LS defaults rather than block the project.
  expect(resolved).toBe("");
});
