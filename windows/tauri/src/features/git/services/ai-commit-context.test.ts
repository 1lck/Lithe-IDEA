import { expect, test } from "bun:test";
import { collectCommitContext } from "./ai-commit-context";
import type { GitDiff, GitFile } from "../types/git.types";

const file = (path: string): GitFile => ({
  path,
  status: "modified",
  staged: true,
  worktree: true,
});
const diff = (path: string, patch = "+change"): GitDiff => ({
  file_path: path,
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
  raw_patch: patch,
});
test("reads all selected paths including staged and unstaged worktree content", async () => {
  const selected = Array.from({ length: 14 }, (_, i) => file(`file${i}`));
  const paths: string[] = [];
  const result = await collectCommitContext(
    "repo",
    selected,
    new AbortController().signal,
    async (_repo, path) => {
      paths.push(path);
      return diff(path);
    },
  );
  expect(paths).toHaveLength(14);
  expect(result).toHaveLength(14);
  expect(result.every((f) => f.diff === "+change")).toBe(true);
});
test("retains original rename path and owner repository", async () => {
  const calls: unknown[] = [];
  await collectCommitContext(
    "workspace",
    [
      {
        ...file("label/new"),
        repositoryPath: "repo",
        repositoryRelativePath: "new",
        repositoryOriginalRelativePath: "old",
      },
    ],
    new AbortController().signal,
    async (...args) => {
      calls.push(args);
      return diff("new");
    },
  );
  expect(calls).toEqual([["repo", "new", false, "old"]]);
});
test("rejects mixed repositories and unreadable paths without partial generation", async () => {
  await expect(
    collectCommitContext(
      "repo",
      [file("one"), { ...file("two"), repositoryPath: "other" }],
      new AbortController().signal,
      async () => {
        throw new Error("must not read");
      },
    ),
  ).rejects.toThrow("AI_COMMIT_MULTIPLE_REPOSITORIES");
  await expect(
    collectCommitContext("repo", [file("one")], new AbortController().signal, async () => null),
  ).rejects.toThrow("AI_COMMIT_DIFF_FAILED");
});
test("hash detects edits beyond truncated text", async () => {
  const prefix = "+".repeat(121000);
  const a = await collectCommitContext(
    "repo",
    [file("one")],
    new AbortController().signal,
    async () => diff("one", prefix + "a"),
  );
  const b = await collectCommitContext(
    "repo",
    [file("one")],
    new AbortController().signal,
    async () => diff("one", prefix + "b"),
  );
  expect(a[0].diff).toBe(b[0].diff);
  expect(a[0].fingerprint).not.toBe(b[0].fingerprint);
});
test("cancellation prevents starting remaining file reads", async () => {
  const controller = new AbortController();
  let started = 0;
  await expect(
    collectCommitContext(
      "repo",
      Array.from({ length: 8 }, (_, i) => file(String(i))),
      controller.signal,
      async (_repo, path) => {
        started++;
        controller.abort();
        return diff(path);
      },
    ),
  ).rejects.toThrow();
  expect(started).toBe(1);
});
