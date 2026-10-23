import { expect, mock, test } from "bun:test";

const owner = mock(async () => ({
  pluginId: "dev.lithe.plugin.php-support",
  displayName: "PHP Support",
  languageId: "php",
}));
const manifest = mock(async () => ({
  executionProviders: [{ languageID: "php", run: {}, test: { projectMarkers: ["composer.json"] } }],
}));
const runPlan = mock(async () => { throw new Error("run plan must not be used for a test"); });
const testPlan = mock(async () => { throw new Error("unsupported test project"); });
const actualLaunch = await import("./declarative-plugin-launch");

mock.module("./declarative-plugin-launch", () => ({
  ...actualLaunch,
  invokeDeclarativePluginOwner: owner,
  getDeclarativePluginManifest: manifest,
  resolveDeclarativeRunPlan: runPlan,
  resolveDeclarativeTestPlan: testPlan,
}));

const { declarativeRunActionsForFile, runDeclarativeAction } = await import("./declarative-plugin-run");

test("discovers separate run and test actions for the owning language", async () => {
  const actions = await declarativeRunActionsForFile("C:/work/tests/ItemTest.php");
  expect(actions.map((action) => action.id)).toEqual([
    "declarative:dev.lithe.plugin.php-support:php:run",
    "declarative:dev.lithe.plugin.php-support:php:test",
  ]);
  expect(actions.map((action) => action.declarativeTest)).toEqual([false, true]);
});

test("a failed test plan never runs the file instead", async () => {
  const actions = await declarativeRunActionsForFile("C:/work/tests/ItemTest.php");
  await expect(runDeclarativeAction(
    actions[1]!,
    "workspace-1",
    "C:/work",
    "C:/work/tests/ItemTest.php",
  )).rejects.toThrow("unsupported test project");
  expect(testPlan).toHaveBeenCalledWith("dev.lithe.plugin.php-support", "php", "C:/work");
  expect(runPlan).not.toHaveBeenCalled();
});
