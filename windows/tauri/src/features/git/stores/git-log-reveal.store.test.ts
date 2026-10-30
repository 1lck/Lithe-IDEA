import { describe, expect, test } from "bun:test";
import { useGitLogRevealStore } from "./git-log-reveal.store";

describe("git log reveal request", () => {
  test("carries the repository and commit until the log consumes it", () => {
    useGitLogRevealStore.getState().request("C:/repo", "a".repeat(40));

    expect(useGitLogRevealStore.getState().pending).toEqual({
      repoPath: "C:/repo",
      commitHash: "a".repeat(40),
    });

    useGitLogRevealStore.getState().clear();
    expect(useGitLogRevealStore.getState().pending).toBeNull();
  });

  test("keeps only the latest request", () => {
    const store = useGitLogRevealStore.getState();

    store.request("C:/repo", "a".repeat(40));
    store.request("C:/repo", "b".repeat(40));

    expect(useGitLogRevealStore.getState().pending?.commitHash).toBe("b".repeat(40));
    store.clear();
  });
});
