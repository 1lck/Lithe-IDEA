import { expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/git/rebase-session-v1.json";
import type { GitRebaseSession } from "../types/git-rebase.types";
import { refreshRebaseAmendDraft, shouldPresentRebaseSession } from "./git-rebase-session";

const session = fixture.sessionResponse as GitRebaseSession;
const empty = { identity: "", message: "", edited: false, stale: false };

test("an external amend refreshes an untouched draft even at the same edit step", () => {
  const original = refreshRebaseAmendDraft(empty, session);
  const amended = { ...session, head: "new-head", currentMessage: "External title\n\nBody\n" };
  const refreshed = refreshRebaseAmendDraft(original, amended);
  expect(refreshed.message).toBe(amended.currentMessage!);
  expect(refreshed.stale).toBe(false);
});

test("external amend preserves an edited draft but requires an explicit reload", () => {
  const original = {
    ...refreshRebaseAmendDraft(empty, session),
    message: "My draft",
    edited: true,
  };
  expect(refreshRebaseAmendDraft(original, session)).toBe(original);
  const amended = { ...session, head: "new-head", currentMessage: "External message" };
  const stale = refreshRebaseAmendDraft(original, amended);
  expect(stale.message).toBe("My draft");
  expect(stale.stale).toBe(true);
  expect(stale.identity).toBe(original.identity);
  const reloaded = refreshRebaseAmendDraft(empty, amended);
  expect(reloaded.message).toBe("External message");
  expect(reloaded.stale).toBe(false);
});

test("an interrupted record cannot block a new plan after an external abort or restart", () => {
  const interrupted = {
    ...session,
    status: "interrupted" as const,
    canContinue: false,
    canSkip: false,
    canAbort: false,
  };
  expect(shouldPresentRebaseSession(interrupted, true, false)).toBe(false);
  expect(shouldPresentRebaseSession(interrupted, true, true)).toBe(false);
  expect(shouldPresentRebaseSession(interrupted, false, false)).toBe(true);
  expect(shouldPresentRebaseSession(session, true, false)).toBe(true);
  expect(shouldPresentRebaseSession({ ...interrupted, canAbort: true }, true, false)).toBe(true);
});

test("advancing to another edit step loads that commit's message", () => {
  const draft = {
    ...refreshRebaseAmendDraft(empty, session),
    message: "Previous draft",
    edited: true,
  };
  const next = {
    ...session,
    currentCommit: "next-commit",
    head: "next-head",
    currentMessage: "Next message",
  };
  expect(refreshRebaseAmendDraft(draft, next)).toEqual(refreshRebaseAmendDraft(empty, next));
});
