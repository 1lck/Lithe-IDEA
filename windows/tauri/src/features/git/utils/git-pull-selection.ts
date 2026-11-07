import type { GitPullPreflight, GitReference } from "../types/git.types";

/** True when the selected branch is the current branch's configured upstream. */
export const isUpstreamPullTarget = (
  reference: GitReference | null,
  preflight: GitPullPreflight,
): boolean =>
  !!reference && !!preflight.upstream && reference.shortName === preflight.upstream;

/**
 * Defaults to the configured upstream. A branch without an upstream leaves the
 * selection empty so the user must explicitly choose what to pull from.
 */
export const defaultPullReference = (
  references: GitReference[],
  preflight: GitPullPreflight,
): GitReference | null =>
  references.find((reference) => isUpstreamPullTarget(reference, preflight)) ?? null;

/** Fast-forward is offered only where the Core can still fast-forward safely. */
export const canUseFastForward = (
  preflight: GitPullPreflight,
  reference: GitReference | null,
): boolean => isUpstreamPullTarget(reference, preflight) && !preflight.diverged;
