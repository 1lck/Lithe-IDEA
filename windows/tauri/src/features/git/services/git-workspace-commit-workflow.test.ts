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
    await workflow.confirm(fixture.request.repositories);
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
    await workflow.confirm(fixture.request.repositories);
    expect(workflow.getState().review?.preparation).toEqual(changed);
    expect(step).not.toHaveBeenCalled();
    await workflow.confirm(fixture.request.repositories);
    expect(prepare.mock.calls[2]![0].reviewed).toEqual(changed.session.plan);
    expect(step).toHaveBeenCalledTimes(1);
  });

  test("confirmation includes newly discovered roots and presents Core's replacement plan", async () => {
    const { workflow, prepare, step } = setup();
    await workflow.prepare(fixture.request);
    const repositories = [...fixture.request.repositories, { id: "C", root: "/workspace/C" }];
    const changed = preparation();
    changed.session.plan.repositories = repositories;
    changed.reviewChanged = true;
    prepare.mockResolvedValueOnce(changed);
    await workflow.confirm(repositories);
    expect(prepare.mock.calls[1]![0].repositories).toEqual(repositories);
    expect(workflow.getState().review?.preparation).toEqual(changed);
    expect(step).not.toHaveBeenCalled();
  });

  test("parent opt-out regenerates a review and retry forwards the prior session", async () => {
    const { workflow, prepare, step } = setup();
    const previous = { ...preparation().session, finished: true, canRetry: true };
    await workflow.prepare({ ...fixture.request, previous });
    await workflow.setIncludeParentReferences(false, fixture.request.repositories);
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
    await workflow.confirm(fixture.request.repositories);
    expect(step.mock.calls[1]![0]).toEqual(progress);
    expect(workflow.getState().session).toEqual(progress);
    expect(workflow.getState().error).toBe("bridge unavailable");
    expect(workflow.getState().busy).toBe(false);
  });

  test("first step transport failure still exposes the initial recovery session", async () => {
    const { workflow, step } = setup();
    await workflow.prepare(fixture.request);
    step.mockRejectedValueOnce(new Error("connection lost"));
    await workflow.confirm(fixture.request.repositories);
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
    const running = workflow.confirm(fixture.request.repositories);
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
    const running = workflow.confirm(fixture.request.repositories);
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

  describe("divergent push destinations", () => {
    const question = (repositoryId: string) => ({
      repositoryId,
      localBranch: "feature/topic",
      remote: "origin",
      upstream: "origin/main",
      upstreamBranch: "main",
    });
    const asking = (...ids: string[]): WorkspaceCommitPreparation => ({
      ...preparation(),
      pushTargetQuestions: ids.map(question),
    });
    const publish = { choice: "publish", remote: "origin", remoteBranch: "feature/topic" } as const;
    const upstream = { choice: "upstream", remote: "origin", remoteBranch: "main" } as const;

    test("asks before anything is reviewed or committed", async () => {
      const { workflow, prepare, step } = setup();
      prepare.mockResolvedValueOnce(asking("A"));
      await workflow.prepare(fixture.request);
      const state = workflow.getState();
      expect(state.pushTargetPrompt?.questions).toEqual([question("A")]);
      expect(state.review).toBeNull();
      expect(state.session).toBeNull();
      expect(step).not.toHaveBeenCalled();
    });

    test("an answer prepares again with the confirmed target and still honours review", async () => {
      const { workflow, prepare, step } = setup();
      prepare.mockResolvedValueOnce(asking("A"));
      await workflow.prepare(fixture.request);
      await workflow.answerPushTargets({ A: upstream });
      expect(prepare.mock.calls[1]![0]).toEqual({
        ...fixture.request,
        pushTargets: { A: upstream },
      });
      expect(workflow.getState().pushTargetPrompt).toBeNull();
      // The fixture still asks for review; answering must not skip that step.
      expect(workflow.getState().review).not.toBeNull();
      expect(step).not.toHaveBeenCalled();
      await workflow.confirm(fixture.request.repositories);
      expect(prepare.mock.calls[2]![0].pushTargets).toEqual({ A: upstream });
      expect(step).toHaveBeenCalledTimes(1);
    });

    test("a routine commit-and-push never sees a question and still reaches execution", async () => {
      const { workflow, prepare, step } = setup();
      const routine = preparation();
      routine.requiresConfirmation = false;
      prepare.mockResolvedValueOnce(routine);
      await workflow.prepare({ ...fixture.request, push: true });
      expect(workflow.getState().pushTargetPrompt).toBeNull();
      expect(prepare.mock.calls[0]![0].pushTargets).toBeUndefined();
      expect(step).toHaveBeenCalledTimes(1);
      expect(workflow.getState().session?.succeeded).toBe(true);
    });

    test("cancelling the question writes nothing and allows starting over", async () => {
      const { workflow, prepare, step } = setup();
      prepare.mockResolvedValueOnce(asking("A"));
      await workflow.prepare(fixture.request);
      workflow.cancelPushTargets();
      expect(workflow.getState().pushTargetPrompt).toBeNull();
      expect(step).not.toHaveBeenCalled();
      expect(workflow.getState().busy).toBe(false);
      await workflow.prepare(fixture.request);
      expect(prepare).toHaveBeenCalledTimes(2);
    });

    test("answers for several repositories accumulate across rounds", async () => {
      const { workflow, prepare } = setup();
      prepare.mockResolvedValueOnce(asking("A", "A/B")).mockResolvedValueOnce(asking("A/B"));
      await workflow.prepare(fixture.request);
      expect(workflow.getState().pushTargetPrompt?.questions.map((q) => q.repositoryId)).toEqual([
        "A",
        "A/B",
      ]);
      await workflow.answerPushTargets({ A: publish });
      expect(workflow.getState().pushTargetPrompt?.questions.map((q) => q.repositoryId)).toEqual([
        "A/B",
      ]);
      await workflow.answerPushTargets({ "A/B": upstream });
      expect(prepare.mock.calls[2]![0].pushTargets).toEqual({ A: publish, "A/B": upstream });
    });

    test("a question raised while confirming keeps the reviewed plan for the next round", async () => {
      const { workflow, prepare, step } = setup();
      await workflow.prepare(fixture.request);
      prepare.mockResolvedValueOnce(asking("A"));
      await workflow.confirm(fixture.request.repositories);
      expect(workflow.getState().review).toBeNull();
      expect(workflow.getState().pushTargetPrompt?.confirmed).toBe(true);
      expect(step).not.toHaveBeenCalled();
      await workflow.answerPushTargets({ A: publish });
      expect(prepare.mock.calls[2]![0].reviewed).toEqual(fixture.preparation.session.plan);
      expect(prepare.mock.calls[2]![0].pushTargets).toEqual({ A: publish });
    });
  });
});
