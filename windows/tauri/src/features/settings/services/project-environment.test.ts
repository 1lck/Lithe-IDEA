import { expect, mock, test } from "bun:test";
import { loadProjectEnvironment, saveProjectEnvironment } from "./project-environment";
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
