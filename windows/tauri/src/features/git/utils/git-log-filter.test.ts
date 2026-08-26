import { describe, expect, test } from "bun:test";
import type { GitCommit } from "../types/git.types";
import { matchesGitLogCommit } from "./git-log-filter";

const COMMIT: GitCommit = {
  hash: "0123456789abcdef",
  shortHash: "0123456",
  parentHashes: ["fedcba9876543210"],
  message: "Add Git graph",
  description: "Render stable lanes",
  author: "Lithe Developer",
  email: "dev@example.com",
  date: "2026-08-16T10:00:00Z",
  decorations: "HEAD -> preview, origin/preview, tag: v0.3.0",
};

describe("Git Log filters", () => {
  test("matches text against the subject, body, and hashes without case sensitivity", () => {
    expect(matchesGitLogCommit(COMMIT, "git GRAPH", "text")).toBe(true);
    expect(matchesGitLogCommit(COMMIT, "stable lanes", "text")).toBe(true);
    expect(matchesGitLogCommit(COMMIT, "0123456", "text")).toBe(true);
    expect(matchesGitLogCommit(COMMIT, "someone else", "text")).toBe(false);
  });

  test("keeps author and branch searches scoped to their displayed metadata", () => {
    expect(matchesGitLogCommit(COMMIT, "dev@example.com", "author")).toBe(true);
    expect(matchesGitLogCommit(COMMIT, "origin/preview", "branch")).toBe(true);
    expect(matchesGitLogCommit(COMMIT, "stable lanes", "author")).toBe(false);
  });
});
