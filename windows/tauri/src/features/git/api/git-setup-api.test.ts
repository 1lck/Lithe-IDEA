import { afterAll, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as events from "../events/git-events";
import fixture from "../../../../../../shared/fixtures/git/repository-setup-v1.json";

const changed = spyOn(events, "emitGitChanged");
let rejected = false;
const invoke = mock(async (_command: string, _payload?: unknown) => {
  if (rejected) throw new Error("Configuration is locked");
  return fixture.unborn;
});
mock.module("@/platform/tauri-core", () => ({ invoke }));
const { getGitRepositorySetup, initializeGitRepository, configureGitIdentity } =
  await import("./git-setup-api");
beforeEach(() => {
  invoke.mockClear();
  changed.mockClear();
  rejected = false;
});
afterAll(() => {
  changed.mockRestore();
  mock.restore();
});

test("inspects and initializes a workspace without requiring repository discovery", async () => {
  const state = await getGitRepositorySetup("C:/fixture");
  expect(state.hasCommits).toBe(false);
  expect(state.branch).toBe("fixture-branch");
  expect(invoke).toHaveBeenLastCalledWith("git.repositorySetup", {
    root: "C:/fixture",
    scope: "local",
  });
  await initializeGitRepository("C:/fixture");
  expect(invoke).toHaveBeenLastCalledWith("git.initialize", { root: "C:/fixture", scope: "local" });
  expect(invoke).toHaveBeenCalledTimes(2);
  expect(changed).toHaveBeenCalledTimes(1);
});

test("preserves explicit global scope and null clear semantics", async () => {
  await configureGitIdentity("C:/fixture", "global", "email", null);
  expect(invoke).toHaveBeenLastCalledWith("git.configureIdentity", {
    root: "C:/fixture",
    scope: "global",
    key: "email",
    value: null,
  });
  expect(changed).toHaveBeenCalledTimes(1);
});

test("propagates failed writes without publishing a success refresh", async () => {
  rejected = true;
  await expect(configureGitIdentity("C:/fixture", "local", "name", "Fixture")).rejects.toThrow(
    "Configuration is locked",
  );
  expect(changed).not.toHaveBeenCalled();
});
