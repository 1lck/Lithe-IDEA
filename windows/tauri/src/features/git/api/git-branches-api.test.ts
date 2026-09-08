import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as gitEvents from "../events/git-events";

const invoke = mock(async (command: string): Promise<unknown> =>
  command === "git_discover_repo" ? "C:/repo" : null,
);
const emitGitChanged = spyOn(gitEvents, "emitGitChanged");

mock.module("@/platform/tauri-core", () => ({ invoke }));

const {
  checkoutGitReference,
  checkoutRemoteBranch,
  createAndCheckoutBranch,
  pushBranch,
  renameBranch,
  setBranchUpstream,
  unsetBranchUpstream,
} = await import("./git-branches-api");

beforeEach(() => {
  invoke.mockReset();
  invoke.mockImplementation(async (command: string) =>
    command === "git_discover_repo" ? "C:/repo" : command === "git.checkoutPreflight" ? { blockingPaths: [] } : null,
  );
  emitGitChanged.mockClear();
});

describe("Git branch reference mutations", () => {
  const remoteReference = {
    fullName: "refs/remotes/origin/feature/orders",
    shortName: "origin/feature/orders",
    kind: "remote" as const,
    peelsToCommit: true,
    isCurrent: false,
  };

  test("checks out a remote reference through the typed Core contract", async () => {
    await expect(
      checkoutRemoteBranch("C:/repo", "refs/remotes/origin/feature/orders"),
    ).resolves.toEqual({ success: true, hasChanges: false, message: "" });
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "checkout",
      reference: "refs/remotes/origin/feature/orders",
      referenceKind: "remote",
    });
  });

  test("checks out a complete remote reference without reducing its identity", async () => {
    await expect(checkoutGitReference("C:/repo", remoteReference)).resolves.toEqual({
      success: true,
      hasChanges: false,
      message: "",
    });
    expect(invoke).toHaveBeenCalledWith("git.checkoutPreflight", {
      repoPath: "C:/repo",
      gitReference: {
        fullName: remoteReference.fullName,
        shortName: remoteReference.shortName,
        kind: remoteReference.kind,
      },
    });
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "checkout",
      gitReference: {
        fullName: remoteReference.fullName,
        shortName: remoteReference.shortName,
        kind: remoteReference.kind,
      },
    });
  });

  test("creates and checks out a local branch at the selected reference", async () => {
    await createAndCheckoutBranch("C:/repo", "feature/local", remoteReference);
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "createBranch",
      name: "feature/local",
      gitReference: {
        fullName: remoteReference.fullName,
        shortName: remoteReference.shortName,
        kind: remoteReference.kind,
      },
      checkout: true,
    });
  });

  test("renames and pushes the selected local branch rather than implicit HEAD", async () => {
    await renameBranch("C:/repo", "feature/old", "feature/new");
    await pushBranch("C:/repo", "feature/new");
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "renameBranch",
      reference: "refs/heads/feature/old",
      name: "feature/new",
    });
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "push",
      reference: "refs/heads/feature/new",
      force: false,
      pushTags: "none",
    });
  });

  test("sets and unsets the selected branch upstream", async () => {
    const upstream = {
      fullName: "refs/remotes/origin/main",
      shortName: "origin/main",
      kind: "remote" as const,
      peelsToCommit: true,
      isCurrent: false,
    };
    await setBranchUpstream("C:/repo", "main", upstream);
    await unsetBranchUpstream("C:/repo", "main");
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "setUpstream",
      name: "main",
      gitReference: {
        fullName: upstream.fullName,
        shortName: upstream.shortName,
        kind: upstream.kind,
      },
    });
    expect(invoke).toHaveBeenCalledWith("git.write", {
      repoPath: "C:/repo",
      operation: "unsetUpstream",
      name: "main",
    });
  });
});
