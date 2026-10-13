import { expect, mock, test } from "bun:test";
import { callIdeExtensionService } from "./ide-extension-host";

test("a worker cannot list or invoke IDE capabilities without its manifest permission", async () => {
  const dependencies = { list: mock(async () => ["workspace-a"]), call: mock(async () => ({})) };
  await expect(
    callIdeExtensionService({}, "ide.authorizedWorkspaceIDs", [], dependencies),
  ).rejects.toThrow("permission");
  await expect(
    callIdeExtensionService({}, "ide.call", ["workspace-a", "lithe_run_start", {}], dependencies),
  ).rejects.toThrow("permission");
  expect(dependencies.list).not.toHaveBeenCalled();
  expect(dependencies.call).not.toHaveBeenCalled();
});

test("worker calls preserve an explicit workspace and the application permission failure", async () => {
  const denied = { error: { code: "PERMISSION_DENIED" } };
  const dependencies = {
    list: mock(async () => ["workspace-a"]),
    call: mock(async (_workspace: string, _name: string, _args: Record<string, unknown>) => denied),
  };
  const manifest = { permissions: { ide: true } };
  expect(
    await callIdeExtensionService(manifest, "ide.authorizedWorkspaceIDs", [], dependencies),
  ).toEqual(["workspace-a"]);
  expect(
    await callIdeExtensionService(
      manifest,
      "ide.call",
      ["workspace-a", "lithe_run_start", { configurationID: "app" }],
      dependencies,
    ),
  ).toEqual(denied);
  expect(dependencies.call).toHaveBeenCalledWith("workspace-a", "lithe_run_start", {
    configurationID: "app",
  });
  await expect(
    callIdeExtensionService(
      manifest,
      "ide.call",
      ["workspace-a", "lithe_run_start", []],
      dependencies,
    ),
  ).rejects.toThrow("JSON arguments");
  expect(dependencies.call).toHaveBeenCalledTimes(1);
});
