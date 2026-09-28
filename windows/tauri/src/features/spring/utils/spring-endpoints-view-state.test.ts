import { describe, expect, test } from "bun:test";
import {
  isSpringEndpointsRefreshing,
  isSpringEndpointsStale,
  resolveSpringEndpointsViewState,
} from "./spring-endpoints-view-state";

describe("resolveSpringEndpointsViewState", () => {
  test("distinguishes initial loading from a refresh with retained rows", () => {
    expect(
      resolveSpringEndpointsViewState({
        phase: "loading",
        loadedRoot: null,
        endpointCount: 0,
        filteredCount: 0,
      }),
    ).toBe("loading");
    expect(
      resolveSpringEndpointsViewState({
        phase: "loading",
        loadedRoot: "C:/work/demo",
        endpointCount: 2,
        filteredCount: 1,
      }),
    ).toBe("list");
    expect(isSpringEndpointsRefreshing("loading", "C:/work/demo")).toBe(true);
  });

  test("does not turn a first-load failure into an empty success", () => {
    expect(
      resolveSpringEndpointsViewState({
        phase: "failed",
        loadedRoot: null,
        endpointCount: 0,
        filteredCount: 0,
      }),
    ).toBe("failed");
    expect(isSpringEndpointsStale("failed", null)).toBe(false);
  });

  test("prioritizes empty and no-match after data exists", () => {
    expect(
      resolveSpringEndpointsViewState({
        phase: "ready",
        loadedRoot: "C:/work/demo",
        endpointCount: 0,
        filteredCount: 0,
      }),
    ).toBe("empty");
    expect(
      resolveSpringEndpointsViewState({
        phase: "ready",
        loadedRoot: "C:/work/demo",
        endpointCount: 2,
        filteredCount: 0,
      }),
    ).toBe("no-match");
  });

  test("keeps stale rows eligible while marking the failed refresh", () => {
    expect(
      resolveSpringEndpointsViewState({
        phase: "failed",
        loadedRoot: "C:/work/demo",
        endpointCount: 2,
        filteredCount: 0,
      }),
    ).toBe("no-match");
    expect(isSpringEndpointsStale("failed", "C:/work/demo")).toBe(true);
  });
});
