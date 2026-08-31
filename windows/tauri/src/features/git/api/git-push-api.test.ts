import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const invoke = mock(async (command: string): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.pushPreview") {
    return {
      localBranch: "feature/push",
      remote: "origin",
      remoteBranch: "feature/push",
      upstream: "origin/feature/push",
      commits: [
        {
          hash: "2222222222222222222222222222222222222222",
          shortHash: "2222222",
          parentHashes: ["1111111111111111111111111111111111111111"],
          authorName: "Lithe Test",
          authorEmail: "test@lithe.local",
          date: "2026/08/31 10:30",
          subject: "Preview push",
          decorations: "HEAD -> feature/push",
        },
      ],
      hasMore: false,
    };
  }
  return null;
});
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const { executeGitPush, getGitPushPreview } = await import("./git-push-api");

beforeEach(() => {
  invoke.mockClear();
  emitGitChanged.mockClear();
});

describe("Git push API", () => {
  test("loads the resolved destination and maps Core commit fields", async () => {
    const preview = await getGitPushPreview("C:/repo", {
      fullName: "refs/heads/feature/push",
      shortName: "feature/push",
      kind: "local",
      isCurrent: true,
    });

    expect(invoke).toHaveBeenCalledWith("git.pushPreview", {
      repoPath: "C:/repo",
      gitReference: {
        fullName: "refs/heads/feature/push",
        shortName: "feature/push",
        kind: "local",
      },
    });
    expect(preview.commits[0]).toMatchObject({
      message: "Preview push",
      author: "Lithe Test",
      email: "test@lithe.local",
    });
  });

  test("executes force-with-lease intent and reachable tags through git.write", async () => {
    await executeGitPush("C:/repo", {
      reference: "feature/push",
      force: true,
      pushTags: "reachable",
    });

    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "push",
      reference: "refs/heads/feature/push",
      force: true,
      pushTags: "reachable",
    });
    expect(emitGitChanged).toHaveBeenCalledWith({
      repoPath: "C:/repo",
      scopes: ["history", "refs", "remotes"],
      source: "force-push",
    });
  });
});
