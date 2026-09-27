import type { SpringIndexPhase } from "../types/spring.types";

export type SpringEndpointsViewState = "loading" | "failed" | "empty" | "no-match" | "list";

interface SpringEndpointsViewStateInput {
  phase: SpringIndexPhase;
  loadedRoot: string | null;
  endpointCount: number;
  filteredCount: number;
}

export function resolveSpringEndpointsViewState({
  phase,
  loadedRoot,
  endpointCount,
  filteredCount,
}: SpringEndpointsViewStateInput): SpringEndpointsViewState {
  if (phase === "loading" && loadedRoot === null) return "loading";
  if (phase === "failed" && loadedRoot === null) return "failed";
  if (endpointCount === 0) return "empty";
  if (filteredCount === 0) return "no-match";
  return "list";
}

export function isSpringEndpointsRefreshing(
  phase: SpringIndexPhase,
  loadedRoot: string | null,
): boolean {
  return phase === "loading" && loadedRoot !== null;
}

export function isSpringEndpointsStale(
  phase: SpringIndexPhase,
  loadedRoot: string | null,
): boolean {
  return phase === "failed" && loadedRoot !== null;
}
