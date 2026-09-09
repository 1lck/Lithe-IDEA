import type { GitRebaseSession } from "../types/git-rebase.types";

export interface GitRebaseAmendDraft {
  identity: string;
  message: string;
  edited: boolean;
  stale: boolean;
}

export function rebaseAmendIdentity(session: GitRebaseSession | null): string {
  return session
    ? `${session.sessionId}:${session.currentCommit}:${session.status}:${session.head}`
    : "";
}

/** Preserve user edits on an external HEAD change until the user explicitly reloads. */
export function refreshRebaseAmendDraft(
  draft: GitRebaseAmendDraft,
  session: GitRebaseSession | null,
): GitRebaseAmendDraft {
  const identity = rebaseAmendIdentity(session);
  if (draft.identity === identity) return draft;
  if (
    draft.edited &&
    session?.status === "edit" &&
    draft.identity.startsWith(`${session.sessionId}:${session.currentCommit}:edit:`)
  )
    return { ...draft, stale: true };
  return { identity, message: session?.currentMessage ?? "", edited: false, stale: false };
}

/** An interrupted diagnostic record must not monopolize a new plan request. */
export function shouldPresentRebaseSession(
  session: GitRebaseSession,
  requestsPlan: boolean,
  alreadyPresented: boolean,
): boolean {
  return (
    !requestsPlan ||
    session.canContinue ||
    session.canSkip ||
    session.canAbort ||
    (alreadyPresented && (session.status === "completed" || session.status === "aborted"))
  );
}
