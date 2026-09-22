import { useEffect, useState } from "react";
import { resolveRunToolchains } from "../api/run-host-api";
import type { EffectiveToolchainState } from "../utils/effective-toolchain";

export interface ResolvedToolchainStates {
  java: EffectiveToolchainState;
  maven: EffectiveToolchainState;
  mavenJava: EffectiveToolchainState;
}

const DETECTING: ResolvedToolchainStates = {
  java: { status: "detecting" },
  maven: { status: "detecting" },
  mavenJava: { status: "detecting" },
};

// Typing a path changes the selection on every key; resolving probes JDKs.
const RESOLVE_DELAY_MS = 300;

export interface ResolvedToolchainDependencies {
  resolve: typeof resolveRunToolchains;
  /** Runs `task` after the typing pause and returns a cancel function. */
  schedule: (task: () => void) => () => void;
}

const defaultDependencies: ResolvedToolchainDependencies = {
  resolve: resolveRunToolchains,
  schedule: (task) => {
    const timer = setTimeout(task, RESOLVE_DELAY_MS);
    return () => clearTimeout(timer);
  },
};

/**
 * Resolves what a launch would use for the given selection. Each change
 * restarts after a short pause, and results for a replaced selection are
 * discarded.
 */
export function useResolvedToolchains(
  root: string | null,
  javaHomePath: string,
  mavenExecutablePath: string,
  mavenJavaHomePath: string,
  dependencies: ResolvedToolchainDependencies = defaultDependencies,
): ResolvedToolchainStates {
  const [state, setState] = useState<ResolvedToolchainStates>(DETECTING);
  useEffect(() => {
    if (!root) return;
    let current = true;
    setState(DETECTING);
    const cancel = dependencies.schedule(() => {
      dependencies.resolve(root, { javaHomePath, mavenExecutablePath, mavenJavaHomePath }).then(
        (resolved) => {
          if (current) setState(resolved);
        },
        (error: unknown) => {
          if (!current) return;
          const failed = { status: "failed", message: String(error) } as const;
          setState({ java: failed, maven: failed, mavenJava: failed });
        },
      );
    });
    return () => {
      current = false;
      cancel();
    };
  }, [root, javaHomePath, mavenExecutablePath, mavenJavaHomePath, dependencies]);
  return state;
}
