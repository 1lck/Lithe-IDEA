import { describe, expect, test } from "bun:test";
import { computeGitGutterChanges } from "@/features/git/utils/git-gutter-changes";
import { GitGutterPeekSession } from "./git-gutter-peek-session";
import { monacoLineDiff } from "./monaco-line-diff";

const BASE = ["a", "b", "c", "d", "e", "f"];
const changesOf = (editor: string[]) => computeGitGutterChanges(BASE, editor, monacoLineDiff) ?? [];
const THREE_CHANGES = ["a", "B", "c", "D", "e", "F"];

describe("Git gutter inline review lifecycle", () => {
  test("opens a change and navigates with wrap-around", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);

    expect(session.open(1, 7)?.index).toBe(1);
    expect(session.navigate("next", 7)?.index).toBe(2);
    expect(session.navigate("next", 7)?.index).toBe(0);
    expect(session.navigate("previous", 7)?.index).toBe(2);
    expect(session.peek?.total).toBe(3);
  });

  test("refuses to open a change list computed for another model version", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    expect(session.open(0, 8)).toBeNull();
    expect(session.peek).toBeNull();
  });

  test("an edit closes the review and invalidates the previous change list", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    const peek = session.open(0, 7)!;

    session.invalidate();

    expect(session.peek).toBeNull();
    expect(session.isCurrent(peek, 7)).toBe(false);
    expect(session.navigate("next", 7)).toBeNull();
  });

  test("a stale review cannot act after a newer review replaces it", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    const first = session.open(0, 7)!;
    const second = session.open(0, 7)!;

    expect(session.isCurrent(first, 7)).toBe(false);
    expect(session.isCurrent(second, 7)).toBe(true);
    expect(session.isCurrent(second, 8)).toBe(false);
  });

  test("a Git refresh keeps an unchanged review open and re-indexes it", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    session.open(2, 7);

    // The first change was staged: the refreshed list no longer contains it.
    const staged = computeGitGutterChanges(["a", "B", "c", "d", "e", "f"], THREE_CHANGES, monacoLineDiff)!;
    const peek = session.setChanges(staged, 7);

    expect(peek?.index).toBe(1);
    expect(peek?.total).toBe(2);
    expect(peek?.change.modifiedLines).toEqual(["F"]);
  });

  test("a refresh that removes the open change closes the review", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    session.open(0, 7);

    const afterStage = computeGitGutterChanges(["a", "B", "c", "d", "e", "f"], THREE_CHANGES, monacoLineDiff)!;
    expect(session.setChanges(afterStage, 7)).toBeNull();
    expect(session.peek).toBeNull();
  });

  test("closing, as on a file switch, clears the open review", () => {
    const session = new GitGutterPeekSession();
    session.setChanges(changesOf(THREE_CHANGES), 7);
    const peek = session.open(1, 7)!;
    session.close();
    expect(session.peek).toBeNull();
    expect(session.isCurrent(peek, 7)).toBe(false);
  });
});
