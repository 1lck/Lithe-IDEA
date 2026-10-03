import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/git/workspace-commit-workflow-v1.json";
import {
  cancelWorkspaceCommit,
  prepareWorkspaceCommit,
  stepWorkspaceCommit,
} from "./git-workspace-commit-api";

let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
beforeEach(() => {
  invoke = spyOn(native, "invoke").mockResolvedValue(fixture.preparation);
});
afterEach(() => invoke.mockRestore());
test("workspace prepare forwards native bindings and user execution provenance", async () => {
  expect(await prepareWorkspaceCommit(fixture.request, "prepare")).toEqual(fixture.preparation);
  expect(invoke).toHaveBeenCalledWith(
    "git.workspaceCommitPrepare",
    { ...fixture.request, operationId: "prepare" },
    { gitExecutionSource: "user" },
  );
});
test("workspace step preserves Core partial result rather than converting it to an error", async () => {
  const session = {
    ...fixture.preparation.session,
    commandFailed: true,
    finished: true,
    canRetry: true,
  };
  invoke.mockResolvedValueOnce(session);
  expect(await stepWorkspaceCommit(fixture.preparation.session, "step")).toEqual(session);
  expect(invoke).toHaveBeenCalledWith(
    "git.workspaceCommitStep",
    { session: fixture.preparation.session, operationId: "step" },
    { gitExecutionSource: "user" },
  );
  await cancelWorkspaceCommit("step");
  expect(invoke).toHaveBeenLastCalledWith("core_cancel", { operationId: "step" });
});

test("workspace preparation forwards the literal changelist scope to Core", async () => {
  const request = {
    ...fixture.request,
    pathScope: { include: false, paths: { A: ["application.yaml"] } },
  };
  await prepareWorkspaceCommit(request, "scoped-prepare");
  expect(invoke).toHaveBeenCalledWith(
    "git.workspaceCommitPrepare",
    { ...request, operationId: "scoped-prepare" },
    { gitExecutionSource: "user" },
  );
});
