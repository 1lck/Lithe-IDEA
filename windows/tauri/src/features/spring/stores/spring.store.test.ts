import { afterEach, describe, expect, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { EMPTY_SPRING_INDEX, type SpringIndex } from "../types/spring.types";
import { useSpringStore } from "./spring.store";

const WORKSPACE_ID = "workspace-a";

function store() {
  return useSpringStore.getStore(WORKSPACE_ID);
}

function endpointIndex(route: string): SpringIndex {
  return {
    ...EMPTY_SPRING_INDEX,
    endpoints: [
      {
        id: route,
        httpMethods: ["GET"],
        route,
        controller: "DemoController",
        method: "demo",
        path: "src/main/java/DemoController.java",
        line: 1,
        column: 1,
      },
    ],
  };
}

afterEach(() => {
  workspaceRuntimeRegistry.resetForTests();
});

describe("Spring store lifecycle", () => {
  test("starts idle and records successful endpoint indexes", () => {
    expect(store().getState().phase).toBe("idle");
    const generation = store().getState().actions.beginLoad("C:/work/demo");
    expect(store().getState().phase).toBe("loading");
    expect(store().getState().isIndexing).toBe(true);

    const index = endpointIndex("/api/demo");
    store().getState().actions.completeLoad(generation, "C:/work/demo", index);

    expect(store().getState().phase).toBe("ready");
    expect(store().getState().loadedRoot).toBe("C:/work/demo");
    expect(store().getState().index.endpoints).toEqual(index.endpoints);
    expect(store().getState().error).toBeNull();
  });

  test("keeps a same-root refresh's successful data while loading", () => {
    const firstGeneration = store().getState().actions.beginLoad("C:/work/demo");
    store()
      .getState()
      .actions.completeLoad(firstGeneration, "C:/work/demo", endpointIndex("/api/old"));

    const refreshGeneration = store().getState().actions.beginLoad("c:/work/demo/");
    expect(refreshGeneration).toBeGreaterThan(firstGeneration);
    expect(store().getState().phase).toBe("loading");
    expect(store().getState().loadedRoot).toBe("C:/work/demo");
    expect(store().getState().index.endpoints).toHaveLength(1);
  });

  test("clears applied data when the logical root changes", () => {
    const firstGeneration = store().getState().actions.beginLoad("C:/work/demo");
    store()
      .getState()
      .actions.completeLoad(firstGeneration, "C:/work/demo", endpointIndex("/api/old"));

    store().getState().actions.beginLoad("D:/other/demo");
    expect(store().getState().phase).toBe("loading");
    expect(store().getState().loadedRoot).toBeNull();
    expect(store().getState().index.endpoints).toEqual([]);
  });

  test("distinguishes first-load failure from a successful empty result", () => {
    const generation = store().getState().actions.beginLoad("C:/work/demo");
    store().getState().actions.failLoad(generation, {
      category: "rootUnavailable",
      detail: "missing",
    });

    expect(store().getState().phase).toBe("failed");
    expect(store().getState().loadedRoot).toBeNull();
    expect(store().getState().error?.category).toBe("rootUnavailable");
  });

  test("retains the last successful result when a refresh fails", () => {
    const firstGeneration = store().getState().actions.beginLoad("C:/work/demo");
    const index = endpointIndex("/api/demo");
    store().getState().actions.completeLoad(firstGeneration, "C:/work/demo", index);

    const refreshGeneration = store().getState().actions.beginLoad("C:/work/demo");
    store().getState().actions.failLoad(refreshGeneration, {
      category: "indexFailed",
      detail: "refresh failed",
    });

    expect(store().getState().phase).toBe("failed");
    expect(store().getState().loadedRoot).toBe("C:/work/demo");
    expect(store().getState().index.endpoints).toEqual(index.endpoints);
    expect(store().getState().error?.detail).toBe("refresh failed");
  });

  test("rejects stale completions and resets to idle", () => {
    const firstGeneration = store().getState().actions.beginLoad("C:/work/demo");
    const secondGeneration = store().getState().actions.beginLoad("C:/work/demo");
    store()
      .getState()
      .actions.completeLoad(firstGeneration, "C:/work/demo", endpointIndex("/api/stale"));
    expect(store().getState().index.endpoints).toEqual([]);

    store()
      .getState()
      .actions.completeLoad(secondGeneration, "C:/work/demo", endpointIndex("/api/current"));
    expect(store().getState().index.endpoints[0]?.route).toBe("/api/current");

    store().getState().actions.reset();
    expect(store().getState().phase).toBe("idle");
    expect(store().getState().requestedRoot).toBeNull();
    expect(store().getState().loadedRoot).toBeNull();
    expect(store().getState().index.endpoints).toEqual([]);
  });
});
