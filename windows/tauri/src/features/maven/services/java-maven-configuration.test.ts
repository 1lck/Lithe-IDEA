import { expect, mock, test } from "bun:test";
import {
  updateJavaMavenConfiguration,
  type JavaMavenConfigurationDependencies,
} from "./java-maven-configuration";
import type { BuildLanguageImport } from "@/features/build-systems/build-language-import";
import type { MavenLaunchContext } from "../types/maven.types";

const scope = { workspaceId: "maven-import", root: "C:/fixture" };
const legacy: MavenLaunchContext = {
  version: 1,
  reactorPath: ".",
  profiles: ["legacy"],
  skipTests: true,
  javaHomePath: "C:/jdk",
};
const imported = {
  version: 1 as const,
  reactorPath: "nested",
  profiles: ["effective"],
  localRepositoryPath: "C:/repo",
};
const updated = {
  kind: "updated" as const,
  settingsChanged: true,
  projectsReloaded: false,
  profilesUpdating: true,
};

function bridge(value: Partial<BuildLanguageImport> = {}) {
  const validate = mock(async () => {});
  const dispose = mock(() => {});
  const calls: unknown[] = [];
  const ports: JavaMavenConfigurationDependencies = {
    prepare: mock(async () => ({
      value: {
        workspaceRoot: scope.root,
        generation: 1,
        identity: "native",
        mavenContext: null,
        javaGradle: null,
        ...value,
      },
      validate,
      dispose,
      assertCurrent: () => {},
    })),
    update: async <T>(command: string, args?: unknown) => {
      calls.push([command, args]);
      return updated as T;
    },
  };
  return { ports, validate, dispose, calls };
}

test("Maven hot update forwards only Core's exact context through the existing session command", async () => {
  const b = bridge({
    mavenContext: imported,
    javaGradle: { wrapperPresent: true, offline: true, userHome: "C:/gradle" },
  });
  expect(await updateJavaMavenConfiguration(scope.root, legacy, true, scope, b.ports)).toEqual(
    updated,
  );
  expect(b.calls).toEqual([
    [
      "lsp_update_maven_configuration",
      {
        workspacePath: scope.root,
        mavenContext: imported,
        reloadProjects: true,
      },
    ],
  ]);
  expect(b.validate).toHaveBeenCalledTimes(1);
  expect(b.dispose).toHaveBeenCalledTimes(1);
}, 2000);

test("without declarative Maven ownership the legacy context remains intact", async () => {
  const b = bridge();
  await updateJavaMavenConfiguration(scope.root, legacy, false, scope, b.ports);
  expect(b.calls).toEqual([
    [
      "lsp_update_maven_configuration",
      { workspacePath: scope.root, mavenContext: legacy, reloadProjects: false },
    ],
  ]);
}, 2000);

test("Gradle-only option edits do not hot update Maven or an unrelated Java tool setting", async () => {
  const b = bridge({ javaGradle: { wrapperPresent: true, offline: true, userHome: "C:/gradle" } });
  expect(await updateJavaMavenConfiguration(scope.root, null, false, scope, b.ports)).toEqual({
    kind: "noSession",
  });
  expect(b.calls).toEqual([]);
}, 2000);

test("a changed or invalid import refuses the hot update instead of falling back to legacy values", async () => {
  const b = bridge({ mavenContext: imported });
  b.validate.mockRejectedValue(new Error("plugin.build.staleContext"));
  await expect(
    updateJavaMavenConfiguration(scope.root, legacy, false, scope, b.ports),
  ).rejects.toThrow("staleContext");
  expect(b.calls).toEqual([]);
  expect(b.dispose).toHaveBeenCalledTimes(1);
}, 2000);
