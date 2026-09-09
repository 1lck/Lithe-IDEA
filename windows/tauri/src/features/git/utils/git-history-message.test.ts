import { describe, expect, test } from "bun:test";
import {
  isGitHeadCommit,
  joinGitCommitMessage,
  splitGitCommitMessage,
} from "./git-history-message";

describe("Complete history messages", () => {
  test("preserves body paragraphs and trailing newline while editing the title", () => {
    const { body } = splitGitCommitMessage("Old title\n\nFirst paragraph.\n\nSecond paragraph.\n");
    expect(joinGitCommitMessage("New title", body)).toBe(
      "New title\n\nFirst paragraph.\n\nSecond paragraph.\n",
    );
  });

  test("recognizes actual HEAD decorations independently of row ordering or branch names", () => {
    expect(isGitHeadCommit({ decorations: "tag: v1, HEAD -> feature/topic" })).toBe(true);
    expect(isGitHeadCommit({ decorations: "HEAD" })).toBe(true);
    expect(isGitHeadCommit({ decorations: "origin/HEAD, feature/HEAD" })).toBe(false);
  });
});
