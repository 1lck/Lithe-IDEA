import type { GitExecutionEvent } from "@/platform/git-execution-events";

export interface GitFetchProgress {
  operationId: string;
  root: string;
  invocationId?: number;
  phase?: GitExecutionEvent["progressDetails"];
}

/** Request lifetime spans preflight, authentication and every remote invocation. */
export function updateGitFetchProgress(
  fetches: GitFetchProgress[],
  event: GitExecutionEvent,
): GitFetchProgress[] {
  if (event.type === "requestStarted" && event.action === "git_fetch") {
    if (fetches.some((fetch) => fetch.operationId === event.operationId)) return fetches;
    return [...fetches, { operationId: event.operationId, root: event.workingDirectory ?? "" }];
  }
  const index = fetches.findIndex((fetch) => fetch.operationId === event.operationId);
  if (index < 0) return fetches;
  if (event.type === "requestFinished") {
    return fetches.filter((fetch) => fetch.operationId !== event.operationId);
  }
  const current = fetches[index]!;
  let next: GitFetchProgress;
  if (event.type === "started") {
    // A new remote or preflight must not inherit the previous transfer's 100%.
    next = { ...current, invocationId: event.invocationId, phase: undefined };
  } else if (event.type === "authentication") {
    next = { ...current, phase: undefined };
  } else if (
    event.invocationId === current.invocationId &&
    event.type === "output" &&
    event.progressDetails
  ) {
    const percent = event.progressDetails.percent;
    next = {
      ...current,
      phase: {
        ...event.progressDetails,
        percent:
          typeof percent === "number" && Number.isFinite(percent)
            ? Math.max(0, Math.min(100, percent))
            : null,
      },
    };
  } else if (event.invocationId === current.invocationId && event.type === "finished") {
    next = { ...current, invocationId: undefined, phase: undefined };
  } else {
    return fetches;
  }
  return fetches.map((fetch, position) => (position === index ? next : fetch));
}
