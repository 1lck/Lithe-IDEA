import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";
import type { GitOperationState } from "../types/git.types";

const invoke = mock(async (_command: string, _args?: unknown): Promise<unknown> => null);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { getConflictMarkerPaths, getOperationState, mergeBranch, rebaseOntoBranch } = await import(
  "./git-integration-api"
);

const operationState = (
  kind: GitOperationState["kind"],
  conflictedPaths: string[] = [],
): GitOperationState => ({
  kind,
  reference: null,
  conflictedPaths,
  step: null,
  total: null,
});

beforeEach(() => {
  invoke.mockReset();
  emitGitChanged.mockClear();
});

describe("Git integration state", () => {
  test("reports a stopped rebase even when no conflicted paths remain", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      if (command === "git_integration_preflight") {
        return { blockingPaths: [], blocksEntirely: false };
      }
      if (command === "git_rebase") throw new Error("rebase stopped");
      if (command === "git_operation_state") return operationState("rebase");
      return null;
    });

    await expect(rebaseOntoBranch("C:/repo", "main")).resolves.toEqual({ status: "stopped" });
    expect(emitGitChanged).toHaveBeenCalledWith({
      repoPath: "C:/repo",
      scopes: ["working-tree", "history", "refs"],
      source: "rebase-rejected",
    });
  });

  test("reports conflicted paths when a merge stops on conflicts", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      if (command === "git_integration_preflight") {
        return { blockingPaths: [], blocksEntirely: false };
      }
      if (command === "git_merge") throw new Error("merge stopped");
      if (command === "git_operation_state") {
        return operationState("merge", ["src/app.ts"]);
      }
      return null;
    });

    await expect(mergeBranch("C:/repo", "feature")).resolves.toEqual({
      status: "conflicts",
      conflictedPaths: ["src/app.ts"],
    });
  });

  test("propagates operation state query failures", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      throw new Error("Core unavailable");
    });

    await expect(getOperationState("C:/repo")).rejects.toThrow("Core unavailable");
  });

  test("propagates conflict marker query failures so commits fail closed", async () => {
    invoke.mockImplementation(async (command: string) => {
      if (command === "git_discover_repo") return "C:/repo";
      throw new Error("Core unavailable");
    });

    await expect(getConflictMarkerPaths("C:/repo")).rejects.toThrow("Core unavailable");
  });
});
