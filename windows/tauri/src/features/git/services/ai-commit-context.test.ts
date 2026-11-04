import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import * as repos from "../api/git-repo-api";
import type { GitFile } from "../types/git.types";
import fixture from "../../../../../../shared/fixtures/git/commit-message-context-v1.json";
import { captureCommitContext, commitSelectionKey, isCommitContextCurrent } from "./ai-commit-context";

const file = (path: string, repositoryPath = "C:/repo"): GitFile => ({
  path, repositoryPath, repositoryRelativePath: path, status: "modified", staged: true,
});
let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
let resolve: ReturnType<typeof spyOn<typeof repos, "resolveRepositoryPathOrThrow">>;
beforeEach(() => { invoke = spyOn(native, "invoke"); resolve = spyOn(repos, "resolveRepositoryPathOrThrow"); });
afterEach(() => { invoke.mockRestore(); resolve.mockRestore(); });

test("passes distinct repository-relative identities and the AI budget to Core", async () => {
  resolve.mockImplementation(async (root) => root);
  invoke.mockResolvedValue(fixture.captureResponse as never);
  const selected = [file("a", "C:/first"), { ...file("new", "C:/second"), originalPath: "old", status: "renamed" as const }];
  const context = await captureCommitContext("C:/first", selected, 8000, new AbortController().signal);
  expect(context.repositories).toEqual([
    { root: "C:/first", files: [{ path: "a", originalPath: undefined, changeKind: "modified" }] },
    { root: "C:/second", files: [{ path: "new", originalPath: "old", changeKind: "renamed" }] },
  ]);
  expect(invoke).toHaveBeenCalledWith("git.commitMessageContext", {
    action: "capture", mode: "worktree", repositories: context.repositories, maximumDiffCharacters: 8000,
  });
  expect(context.files[0].originalCharacters).toBe(8);
  expect(context.token).toBe(fixture.captureResponse.token);
});

test("checks captured state through Core and rejects changes at the same path", async () => {
  const context = { files: [], token: "captured", repositories: [{ root: "C:/repo", files: [] }] };
  invoke.mockResolvedValue({ isCurrent: false } as never);
  expect(await isCommitContextCurrent(context, new AbortController().signal)).toBe(false);
  expect(invoke).toHaveBeenCalledWith("git.commitMessageContext", {
    action: "check", mode: "worktree", repositories: context.repositories, token: "captured",
  });
});

test("does not start Core capture after cancellation during repository resolution", async () => {
  const controller = new AbortController();
  resolve.mockImplementation(async (root) => { controller.abort(); return root; });
  await expect(captureCommitContext("C:/repo", [file("a")], 8000, controller.signal)).rejects.toThrow();
  expect(invoke).not.toHaveBeenCalled();
});

test("selection keys include repository, source path and status", () => {
  const base = file("a");
  expect(commitSelectionKey("C:/repo", [base])).not.toBe(commitSelectionKey("C:/repo", [{ ...base, originalPath: "old" }]));
  expect(commitSelectionKey("C:/repo", [base])).not.toBe(commitSelectionKey("C:/repo", [{ ...base, repositoryPath: "C:/other" }]));
});

test("a cancelled Core check cannot authorize a late result", async () => {
  const controller = new AbortController();
  let release!: (value: unknown) => void;
  invoke.mockImplementation(() => new Promise((resolvePromise) => { release = resolvePromise; }) as never);
  const context = { files: [], token: "captured", repositories: [] };
  const pending = isCommitContextCurrent(context, controller.signal);
  controller.abort();
  release({ isCurrent: true });
  await expect(pending).rejects.toThrow();
});

test("rejects malformed or incomplete Core evidence before generation", async () => {
  resolve.mockImplementation(async (root) => root);
  invoke.mockResolvedValue({ ...fixture.captureResponse, token: "invalid" } as never);
  await expect(captureCommitContext("C:/repo", [file("a")], 8000, new AbortController().signal))
    .rejects.toThrow("AI_COMMIT_DIFF_FAILED");
});
