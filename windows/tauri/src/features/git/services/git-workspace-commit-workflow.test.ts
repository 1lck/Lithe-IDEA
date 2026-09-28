import { describe, expect, mock, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/git/workspace-commit-workflow-v1.json";
import {
  createWorkspaceCommitWorkflow,
  type WorkspaceCommitPort,
} from "./git-workspace-commit-workflow";
import type {
  WorkspaceCommitPreparation,
  WorkspaceCommitSession,
} from "../types/git-workspace-commit.types";

const preparation = (): WorkspaceCommitPreparation => structuredClone(fixture.preparation);
const completed = (): WorkspaceCommitSession => ({
  ...preparation().session,
  finished: true,
  succeeded: true,
  canRetry: false,
});
const setup = () => {
  const prepare = mock<WorkspaceCommitPort["prepare"]>(async () => preparation());
  const step = mock<WorkspaceCommitPort["step"]>(async () => completed());
  const cancel = mock<WorkspaceCommitPort["cancel"]>(async () => {});
  return {
    prepare,
    step,
    cancel,
    workflow: createWorkspaceCommitWorkflow({ prepare, step, cancel }),
  };
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("workspace commit native continuation adapter", () => {
  test("requires review and returns the shared plan unchanged before executing steps", async () => {
    const { workflow, prepare, step } = setup();
    await workflow.prepare(fixture.request);
    expect(workflow.getState().review?.preparation).toEqual(fixture.preparation);
    expect(step).not.toHaveBeenCalled();
    await workflow.confirm();
    expect(prepare.mock.calls[1]![0]).toEqual({
      ...fixture.request,
      reviewed: fixture.preparation.session.plan,
    });
    expect(step.mock.calls[0]![0]).toEqual(fixture.preparation.session);
    expect(workflow.getState().session?.succeeded).toBe(true);
    const ids = [...prepare.mock.calls, ...step.mock.calls].map((call) => call[1]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  test("a changed Core plan requires another confirmation without executing the old one", async () => {
    const { workflow, prepare, step } = setup();
    await workflow.prepare(fixture.request);
    const changed = preparation();
    changed.reviewChanged = true;
    changed.session.plan.states["A/B"]!.stagedPaths.push("new.ts");
    prepare.mockResolvedValueOnce(changed);
    await workflow.confirm();
    expect(workflow.getState().review?.preparation).toEqual(changed);
    expect(step).not.toHaveBeenCalled();
    await workflow.confirm();
    expect(prepare.mock.calls[2]![0].reviewed).toEqual(changed.session.plan);
    expect(step).toHaveBeenCalledTimes(1);
  });

  test("parent opt-out regenerates a review and retry forwards the prior session", async () => {
    const { workflow, prepare, step } = setup();
    const previous = { ...preparation().session, finished: true, canRetry: true };
    await workflow.prepare({ ...fixture.request, previous });
    await workflow.setIncludeParentReferences(false);
    expect(prepare.mock.calls[1]![0]).toEqual({
      ...fixture.request,
      previous,
      includeParentReferences: false,
      reviewed: undefined,
    });
    expect(step).not.toHaveBeenCalled();
  });

  test("drives each Core result unchanged and retains recovery after a transport failure", async () => {
    const { workflow, step } = setup();
    await workflow.prepare(fixture.request);
    const progress = preparation().session;
    progress.cursor = 1;
    progress.results["A/B"] = {
      committed: true,
      pushed: false,
      status: "committedPushPending",
      detail: "",
    };
    step.mockResolvedValueOnce(progress).mockRejectedValueOnce(new Error("bridge unavailable"));
    await workflow.confirm();
    expect(step.mock.calls[1]![0]).toEqual(progress);
    expect(workflow.getState().session).toEqual(progress);
    expect(workflow.getState().error).toBe("bridge unavailable");
    expect(workflow.getState().busy).toBe(false);
  });

  test("first step transport failure still exposes the initial recovery session", async () => {
    const { workflow, step } = setup();
    await workflow.prepare(fixture.request);
    step.mockRejectedValueOnce(new Error("connection lost"));
    await workflow.confirm();
    expect(workflow.getState().session).toEqual(fixture.preparation.session);
    workflow.dismiss();
    expect(workflow.getState().session).toBeNull();
  });

  test("scope disposal cancels the request, preserves reconciled commit and starts no next step", async () => {
    const { workflow, step, cancel } = setup();
    const entered = deferred<void>();
    const release = deferred<WorkspaceCommitSession>();
    step.mockImplementationOnce(async () => {
      entered.resolve();
      return release.promise;
    });
    await workflow.prepare(fixture.request);
    const running = workflow.confirm();
    const progress = preparation().session;
    progress.results["A/B"] = {
      committed: true,
      pushed: false,
      status: "committedPushPending",
      detail: "",
    };
    try {
      await entered.promise;
      workflow.dispose();
      expect(cancel).toHaveBeenCalledWith(step.mock.calls[0]![1]);
    } finally {
      release.resolve(progress);
      await running;
    }
    expect(step).toHaveBeenCalledTimes(1);
    expect(workflow.getState().session).toEqual(progress);
    expect(workflow.getState().busy).toBe(false);
  }, 1000);

  test("user cancellation leaves continuation decisions to Core so independent repositories can finish", async () => {
    const { workflow, step } = setup();
    const entered = deferred<void>();
    const release = deferred<WorkspaceCommitSession>();
    step.mockImplementationOnce(async () => {
      entered.resolve();
      return release.promise;
    });
    await workflow.prepare(fixture.request);
    const running = workflow.confirm();
    try {
      await entered.promise;
      workflow.cancel();
    } finally {
      release.resolve({ ...preparation().session, commandFailed: true });
      await running;
    }
    expect(step).toHaveBeenCalledTimes(2);
    expect(workflow.getState().session?.finished).toBe(true);
  }, 1000);

  test("scope disposal during preparation cannot open a stale review or write repositories", async () => {
    const { workflow, prepare, step } = setup();
    const release = deferred<WorkspaceCommitPreparation>();
    prepare.mockImplementationOnce(() => release.promise);
    const running = workflow.prepare(fixture.request);
    try {
      workflow.dispose();
    } finally {
      release.resolve(preparation());
      await running;
    }
    expect(workflow.getState().review).toBeNull();
    expect(step).not.toHaveBeenCalled();
  }, 1000);
});
