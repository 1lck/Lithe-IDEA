import { describe, expect, test } from "bun:test";
import type { GitPullPreflight, GitReference } from "../types/git.types";
import {
  canUseFastForward,
  defaultPullReference,
  defaultPullStrategy,
  isUpstreamPullTarget,
} from "./git-pull-selection";

const preflight = (overrides: Partial<GitPullPreflight> = {}): GitPullPreflight => ({
  upstream: "origin/main",
  ahead: 0,
  behind: 1,
  diverged: false,
  hasLocalChanges: false,
  ...overrides,
});

const remote = (shortName: string): GitReference => ({
  fullName: `refs/remotes/${shortName}`,
  shortName,
  kind: "remote",
  peelsToCommit: true,
  isCurrent: false,
});

describe("Pull dialog selection defaults", () => {
  test("defaults to the configured upstream when it is available", () => {
    const references = [remote("origin/release"), remote("origin/main")];
    const selected = defaultPullReference(references, preflight());

    expect(selected?.shortName).toBe("origin/main");
    expect(isUpstreamPullTarget(selected, preflight())).toBe(true);
  });

  test("leaves the selection empty when there is no configured upstream", () => {
    const references = [remote("origin/release"), remote("origin/main")];

    expect(defaultPullReference(references, preflight({ upstream: null }))).toBeNull();
    // An upstream that is missing from the loaded references is also not guessed.
    expect(defaultPullReference([remote("origin/release")], preflight())).toBeNull();
  });

  test("defaults to merge and never preselects fast-forward only", () => {
    // Even a linear upstream keeps the safe merge default; ff-only is opt-in.
    expect(defaultPullStrategy()).toBe("merge");
    expect(canUseFastForward(preflight(), remote("origin/main"))).toBe(true);
    // Diverged history or another branch cannot be safely fast-forwarded.
    expect(canUseFastForward(preflight({ diverged: true }), remote("origin/main"))).toBe(false);
    expect(canUseFastForward(preflight(), remote("origin/release"))).toBe(false);
  });
});
