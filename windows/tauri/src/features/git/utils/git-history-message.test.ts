import { describe, expect, test } from "bun:test";
import {
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


});
