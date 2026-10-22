import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const invoke = mock(async (command: string): Promise<unknown> => {
  if (command === "git_discover_repo") return "C:/repo";
  if (command === "git.pushPreview") {
    return {
      localBranch: "feature/push",
      localHead: "2222222222222222222222222222222222222222",
      remote: "origin",
      remoteBranch: "feature/push",
      targetKind: "tracking",
      createsRemoteBranch: false,
      remoteTrackingOid: "1111111111111111111111111111111111111111",
      tags: [],
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

const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

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
      peelsToCommit: true,
      isCurrent: true,
    });

    expect(invoke).toHaveBeenCalledWith("git.pushPreview", {
      repoPath: "C:/repo",
      gitReference: {
        fullName: "refs/heads/feature/push",
        shortName: "feature/push",
        kind: "local",
      },
      pushTags: "none",
    });
    expect(preview.commits[0]).toMatchObject({
      message: "Preview push",
      author: "Lithe Test",
      email: "test@lithe.local",
    });
  });

  test("executes force-with-lease intent and reachable tags through git.write", async () => {
    const expectedPush = {
      localBranch: "feature/push",
      localHead: "2222222222222222222222222222222222222222",
      remote: "origin",
      remoteBranch: "feature/push",
      remoteTrackingOid: "1111111111111111111111111111111111111111",
      tags: [],
    };
    await executeGitPush("C:/repo", {
      reference: "feature/push",
      expectedPush,
      force: true,
      pushTags: "reachable",
    });

    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "push",
      reference: "refs/heads/feature/push",
      expectedPush,
      force: true,
      pushTags: "reachable",
    });
    expect(emitGitChanged).toHaveBeenCalledWith({
      repoPath: "C:/repo",
      scopes: ["history", "refs", "remotes"],
      source: "force-push",
    });
  });

  test("previews the destination that a divergent choice would update", async () => {
    await getGitPushPreview("C:/repo", "feature/topic", "none", "upstream");

    expect(invoke).toHaveBeenCalledWith("git.pushPreview", {
      repoPath: "C:/repo",
      reference: "refs/heads/feature/topic",
      pushTags: "none",
      pushTarget: "upstream",
    });
  });

  test("omits pushTarget for a routine same-named push", async () => {
    await executeGitPush("C:/repo", {
      reference: "feature/push",
      expectedPush: {
        localBranch: "feature/push",
        localHead: "2222222222222222222222222222222222222222",
        remote: "origin",
        remoteBranch: "feature/push",
        targetKind: "tracking",
        remoteTrackingOid: "1111111111111111111111111111111111111111",
        tags: [],
      },
    });

    const calls = invoke.mock.calls as unknown as [string, Record<string, unknown>][];
    const payload = calls[calls.length - 1][1];
    expect(payload).not.toHaveProperty("pushTarget");
    expect(payload.operation).toBe("push");
  });

  test("forwards the confirmed destination for a divergent branch", async () => {
    await executeGitPush("C:/repo", {
      reference: "feature/topic",
      expectedPush: {
        localBranch: "feature/topic",
        localHead: "2222222222222222222222222222222222222222",
        remote: "origin",
        remoteBranch: "feature/topic",
        targetKind: "divergent",
        remoteTrackingOid: "1111111111111111111111111111111111111111",
        tags: [],
      },
      pushTarget: "publish",
    });

    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "push",
      reference: "refs/heads/feature/topic",
      pushTarget: "publish",
      expectedPush: {
        localBranch: "feature/topic",
        localHead: "2222222222222222222222222222222222222222",
        remote: "origin",
        remoteBranch: "feature/topic",
        targetKind: "divergent",
        remoteTrackingOid: "1111111111111111111111111111111111111111",
        tags: [],
      },
      force: false,
      pushTags: "none",
    });
  });
});
