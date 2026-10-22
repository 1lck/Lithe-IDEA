import { createStore } from "zustand/vanilla";
import type {
  WorkspaceCommitPreparation,
  WorkspaceCommitPushTarget,
  WorkspaceCommitPushTargetQuestion,
  WorkspaceCommitRequest,
  WorkspaceCommitSession,
  WorkspaceRepositoryBinding,
} from "../types/git-workspace-commit.types";

export interface WorkspaceCommitPort {
  prepare: (
    request: WorkspaceCommitRequest,
    operationId: string,
  ) => Promise<WorkspaceCommitPreparation>;
  step: (session: WorkspaceCommitSession, operationId: string) => Promise<WorkspaceCommitSession>;
  cancel: (operationId: string) => Promise<void>;
}
interface Review {
  request: WorkspaceCommitRequest;
  preparation: WorkspaceCommitPreparation;
}
/** Pushes Core cannot run until the user picks a destination; nothing is committed yet. */
interface PushTargetPrompt {
  request: WorkspaceCommitRequest;
  questions: WorkspaceCommitPushTargetQuestion[];
  confirmed: boolean;
  forceReview: boolean;
}
interface WorkflowState {
  busy: boolean;
  session: WorkspaceCommitSession | null;
  review: Review | null;
  pushTargetPrompt: PushTargetPrompt | null;
  error: string | null;
}

/** UI lifecycle only. Core owns dependency ordering, guards, outcomes and retry policy. */
export function createWorkspaceCommitWorkflow(port: WorkspaceCommitPort) {
  const store = createStore<WorkflowState>(() => ({
    busy: false,
    session: null,
    review: null,
    pushTargetPrompt: null,
    error: null,
  }));
  let stopped = false;
  let operationId: string | null = null;

  const invoke = async <T>(operation: (id: string) => Promise<T>): Promise<T> => {
    operationId = crypto.randomUUID();
    try {
      return await operation(operationId);
    } finally {
      operationId = null;
    }
  };
  const execute = async (initial: WorkspaceCommitSession) => {
    let session = initial;
    // Publish before invoking native code: a lost reply must still offer recovery.
    store.setState({ session, review: null });
    while (!session.finished && !stopped) {
      session = await invoke((id) => port.step(session, id));
      // A cancelled step may have completed a commit. Keep Core's reconciled result.
      store.setState({ session });
    }
  };
  const prepare = async (
    request: WorkspaceCommitRequest,
    confirmed = false,
    forceReview = false,
  ) => {
    if (store.getState().busy) return;
    stopped = false;
    store.setState({
      busy: true,
      error: null,
      pushTargetPrompt: null,
      ...(store.getState().session?.succeeded ? { session: null } : {}),
    });
    try {
      const preparation = await invoke((id) => port.prepare(request, id));
      if (stopped) return;
      const questions = preparation.pushTargetQuestions ?? [];
      if (questions.length > 0) {
        // Neither review nor execution may start: a commit written now could not be
        // pushed, and Core would refuse the first step anyway.
        store.setState({
          review: null,
          pushTargetPrompt: { request, questions, confirmed, forceReview },
        });
      } else if (
        forceReview ||
        preparation.reviewChanged ||
        (!confirmed && preparation.requiresConfirmation)
      ) {
        store.setState({ review: { request, preparation } });
      } else {
        await execute(preparation.session);
      }
    } catch (error) {
      if (!stopped)
        store.setState({ error: error instanceof Error ? error.message : String(error) });
    } finally {
      store.setState({ busy: false });
    }
  };
  return {
    ...store,
    prepare: (request: WorkspaceCommitRequest) => prepare(request),
    confirm: (repositories: WorkspaceRepositoryBinding[]) => {
      const review = store.getState().review;
      if (!review) return Promise.resolve();
      return prepare(
        { ...review.request, repositories, reviewed: review.preparation.session.plan },
        true,
      );
    },
    setIncludeParentReferences: (
      includeParentReferences: boolean,
      repositories: WorkspaceRepositoryBinding[],
    ) => {
      const review = store.getState().review;
      if (!review) return Promise.resolve();
      return prepare(
        { ...review.request, repositories, includeParentReferences, reviewed: undefined },
        false,
        true,
      );
    },
    /**
     * Answers the pending destination questions and prepares again. Core re-validates
     * every answer against the repository's current tracking configuration.
     */
    answerPushTargets: (answers: Record<string, WorkspaceCommitPushTarget>) => {
      const pending = store.getState().pushTargetPrompt;
      if (!pending) return Promise.resolve();
      return prepare(
        { ...pending.request, pushTargets: { ...pending.request.pushTargets, ...answers } },
        pending.confirmed,
        pending.forceReview,
      );
    },
    cancelPushTargets: () => {
      if (!store.getState().busy) store.setState({ pushTargetPrompt: null });
    },
    closeReview: () => {
      if (!store.getState().busy) store.setState({ review: null, error: null });
    },
    dismiss: () => {
      if (!store.getState().busy)
        store.setState({ session: null, review: null, pushTargetPrompt: null, error: null });
    },
    // User cancellation applies to the current command. Core can continue unrelated roots.
    cancel: () => {
      if (operationId)
        void port.cancel(operationId).catch((error) => {
          store.setState({ error: error instanceof Error ? error.message : String(error) });
        });
    },
    // Leaving the workspace also prevents the adapter from dispatching another step.
    dispose: () => {
      stopped = true;
      store.setState({ review: null, pushTargetPrompt: null });
      if (operationId) void port.cancel(operationId).catch(() => {});
    },
  };
}
