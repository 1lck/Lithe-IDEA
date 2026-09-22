import { expect, mock, test } from "bun:test";
import {
  loadProjectEnvironment,
  ProjectEnvironmentSaveError,
  saveProjectEnvironment,
  saveProjectEnvironmentSettings,
} from "./project-environment";
import { EMPTY_GLOBAL_TOOLCHAIN } from "@/features/run/types/run.types";

function fixture() {
  return {
    inspectRunConfiguration: mock(async () => ({
      status: "missing",
      toolchain: { java: { homePath: "C:/fixture/jdk-21" } },
    })),
    discoverRunToolchains: mock(async () => ({
      java: [{ homePath: "C:/fixture/detected-jdk", version: "21", vendor: "fixture" }],
      maven: [],
      runtimes: [],
    })),
    updateProjectToolchain: mock(async () => ({ document: '{"version":2,"configurations":[]}' })),
    writeRunDocuments: mock(async () => {}),
  };
}

test("project settings load before generation without persisting automatic discovery", async () => {
  const dependencies = fixture();
  const result = await loadProjectEnvironment("C:/fixture/project", dependencies);
  expect(result.toolchain.javaHomePath).toBe("C:/fixture/jdk-21");
  expect(result.toolchain.mavenExecutablePath).toBe("");
  expect(dependencies.inspectRunConfiguration).toHaveBeenCalledWith("C:/fixture/project", false);
  expect(dependencies.writeRunDocuments).not.toHaveBeenCalled();
});

test("saving project defaults writes only the Core-prepared local document", async () => {
  const dependencies = fixture();
  await saveProjectEnvironment("C:/fixture/project", EMPTY_GLOBAL_TOOLCHAIN, dependencies);
  expect(dependencies.writeRunDocuments).toHaveBeenCalledWith("C:/fixture/project", [
    { relativePath: "run/local.json", contents: '{"version":2,"configurations":[]}' },
  ]);
});

test("failed discovery leaves saved paths available for manual correction", async () => {
  const dependencies = fixture();
  dependencies.discoverRunToolchains.mockImplementation(async () => {
    throw new Error("broken JDK");
  });
  const result = await loadProjectEnvironment("C:/fixture/project", dependencies);
  expect(result.toolchain.javaHomePath).toBe("C:/fixture/jdk-21");
  expect(result.discoveryError).toContain("broken JDK");
  expect(result.discovered.java).toEqual([]);
});

test("failed preparation never writes and failed persistence is reported", async () => {
  const dependencies = fixture();
  dependencies.updateProjectToolchain.mockImplementation(async () => {
    throw new Error("invalid document");
  });
  await expect(
    saveProjectEnvironment("C:/fixture/project", EMPTY_GLOBAL_TOOLCHAIN, dependencies),
  ).rejects.toThrow("invalid document");
  expect(dependencies.writeRunDocuments).not.toHaveBeenCalled();
  const failedWrite = fixture();
  failedWrite.writeRunDocuments.mockImplementation(async () => {
    throw new Error("permission denied");
  });
  await expect(
    saveProjectEnvironment("C:/fixture/project", EMPTY_GLOBAL_TOOLCHAIN, failedWrite),
  ).rejects.toThrow("permission denied");
});

const ROOT = "C:/fixture/project";
const MAVEN_SETTINGS = {
  settingsPath: "C:/fixture/settings.xml",
  localRepositoryPath: "",
  mavenExecutablePath: "",
  javaHomePath: "",
};

/**
 * A Run store whose reload finishes only when the test releases it. Tests that
 * use it carry a local deadline so a save that waits on the reload fails fast.
 */
function runTarget(status = "ready", invalidMessage?: string) {
  let release: () => void = () => {};
  const loadProject = mock(
    () =>
      new Promise<void>((resolve) => {
        release = resolve;
      }),
  );
  const state = { root: ROOT as string | null, status, invalidMessage, actions: { loadProject } };
  return { target: { getState: () => state }, loadProject, release: () => release() };
}

test("saving completes before Run finishes refreshing an identifying project", async () => {
  const dependencies = fixture();
  const run = runTarget();
  const saveLocalConfiguration = mock(async () => {});
  const toolchain = { ...EMPTY_GLOBAL_TOOLCHAIN, mavenJavaHomePath: "C:/fixture/maven-jdk" };

  // The reload is still pending, yet the save has already returned.
  const { runRefresh } = await saveProjectEnvironmentSettings(
    ROOT,
    toolchain,
    {
      maven: {
        settings: MAVEN_SETTINGS,
        store: { getState: () => ({ root: ROOT, actions: { saveLocalConfiguration } }) },
      },
      run: run.target,
    },
    dependencies,
  );
  expect(dependencies.writeRunDocuments).toHaveBeenCalledTimes(1);
  expect(saveLocalConfiguration).toHaveBeenCalledWith({
    ...MAVEN_SETTINGS,
    javaHomePath: "C:/fixture/maven-jdk",
  });
  expect(run.loadProject).toHaveBeenCalledWith(ROOT);

  run.release();
  expect(await runRefresh).toBeNull();
}, 1_000);

test("a failed Run refresh is reported after the save", async () => {
  const run = runTarget("invalid", "broken local.json");
  const { runRefresh } = await saveProjectEnvironmentSettings(
    ROOT,
    EMPTY_GLOBAL_TOOLCHAIN,
    { maven: null, run: run.target },
    fixture(),
  );
  run.release();
  expect(await runRefresh).toBe("broken local.json");
}, 1_000);

test("Run bound to another project is left alone", async () => {
  const run = runTarget();
  run.target.getState().root = "C:/fixture/other";
  const { runRefresh } = await saveProjectEnvironmentSettings(
    ROOT,
    EMPTY_GLOBAL_TOOLCHAIN,
    { maven: null, run: run.target },
    fixture(),
  );
  expect(await runRefresh).toBeNull();
  expect(run.loadProject).not.toHaveBeenCalled();
});

test("a Maven write failure reports that project defaults were already saved", async () => {
  const run = runTarget();
  const failure = saveProjectEnvironmentSettings(
    ROOT,
    EMPTY_GLOBAL_TOOLCHAIN,
    {
      maven: {
        settings: MAVEN_SETTINGS,
        store: {
          getState: () => ({
            root: ROOT,
            actions: {
              saveLocalConfiguration: async () => {
                throw new Error("maven.json is read-only");
              },
            },
          }),
        },
      },
      run: run.target,
    },
    fixture(),
  );
  const error = await failure.then(
    () => null,
    (cause: unknown) => cause,
  );
  expect(error).toBeInstanceOf(ProjectEnvironmentSaveError);
  expect((error as ProjectEnvironmentSaveError).defaultsWritten).toBe(true);
  expect((error as ProjectEnvironmentSaveError).message).toContain("maven.json is read-only");
  expect(run.loadProject).not.toHaveBeenCalled();
});
