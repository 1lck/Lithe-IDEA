import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { DEFAULT_COMMIT_AI, newCommitProvider } from "@/features/git/types/ai-commit";
import type { GitDiff } from "@/features/git/types/git.types";
import { comparisonFiles, generatePullRequestDescription } from "./pull-request-description-ai";

let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
beforeEach(() => {
  invoke = spyOn(native, "invoke");
});
afterEach(() => invoke.mockRestore());

const diff = (overrides: Partial<GitDiff>): GitDiff => ({
  file_path: "src/a.ts",
  is_new: false,
  is_deleted: false,
  is_renamed: false,
  lines: [],
  ...overrides,
});

test("reports every changed file so Core applies its evidence and sensitive-path policy", () => {
  expect(
    comparisonFiles([
      diff({
        lines: [
          { line_type: "header", content: "@@ -1 +1 @@" },
          { line_type: "removed", content: "old" },
          { line_type: "added", content: "new" },
          { line_type: "context", content: "same" },
        ],
      }),
      diff({ file_path: "logo.png", is_new: true, is_binary: true }),
      diff({ file_path: "config/credentials.json", raw_patch: "+secret-shaped", is_deleted: true }),
    ]),
  ).toEqual([
    { path: "src/a.ts", changeKind: "modified", diff: "@@ -1 +1 @@\n-old\n+new\n same" },
    { path: "logo.png", changeKind: "added", diff: "" },
    { path: "config/credentials.json", changeKind: "deleted", diff: "+secret-shaped" },
  ]);
});

test("routes the comparison through the native AI commit adapter without credentials", async () => {
  const provider = { ...newCommitProvider("p1"), endpoint: "https://api.example.com/v1", model: "m" };
  invoke.mockResolvedValue({ title: "Title", description: "Body" } as never);
  const draft = await generatePullRequestDescription(
    { ...DEFAULT_COMMIT_AI, providers: [provider], activeProviderId: "p1" },
    { repository: "C:/repo", base: "main", head: "topic", files: [] },
    new AbortController().signal,
  );
  expect(draft).toEqual({ title: "Title", description: "Body" });
  const [command, args] = invoke.mock.calls[0] as [string, Record<string, unknown>];
  expect(command).toBe("ai_commit_pull_request");
  expect(args.provider).toEqual(provider);
  expect(args.options).toEqual({
    language: "english",
    format: "standard",
    customTemplate: "",
    maximumDiffCharacters: 32_000,
    reasoningEffort: "default",
  });
  expect(args.comparison).toEqual({
    repository: "C:/repo",
    base: "main",
    head: "topic",
    files: [],
    commitMessages: [],
  });
});

test("fails before IPC when no AI commit provider is active", async () => {
  await expect(
    generatePullRequestDescription(
      DEFAULT_COMMIT_AI,
      { repository: "C:/repo", base: "main", head: "topic", files: [] },
      new AbortController().signal,
    ),
  ).rejects.toThrow("AI_COMMIT_INVALID_PROVIDER");
  expect(invoke).not.toHaveBeenCalled();
});
