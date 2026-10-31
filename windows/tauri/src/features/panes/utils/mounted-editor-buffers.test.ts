import { describe, expect, test } from "bun:test";
import { assignEditorSurfaceKeys, reconcileMountedEditorBuffers } from "./mounted-editor-buffers";

describe("mounted editor buffer retention", () => {
  test("does not publish a new mounted set when switching among mounted editors", () => {
    const first = reconcileMountedEditorBuffers(
      { recentIds: [], mountedIds: [] },
      ["one", "two"],
      "one",
      8,
    );
    const second = reconcileMountedEditorBuffers(first, ["one", "two"], "two", 8);
    const switchedBack = reconcileMountedEditorBuffers(second, ["one", "two"], "one", 8);

    expect(switchedBack.recentIds).toEqual(["one", "two"]);
    expect(switchedBack.mountedIds).toBe(second.mountedIds);
  });

  test("evicts the least recent mounted editor only when capacity changes membership", () => {
    const mounted = { recentIds: ["two", "one"], mountedIds: ["two", "one"] };
    const next = reconcileMountedEditorBuffers(mounted, ["one", "two", "three"], "three", 2);

    expect(next.recentIds).toEqual(["three", "two"]);
    expect(next.mountedIds).toEqual(["three", "two"]);
    expect(next.mountedIds).not.toBe(mounted.mountedIds);
  });

  test("unmounts editors that are no longer open", () => {
    const mounted = { recentIds: ["two", "one"], mountedIds: ["two", "one"] };
    const next = reconcileMountedEditorBuffers(mounted, ["two"], "two", 8);

    expect(next.mountedIds).toEqual(["two"]);
  });
});

describe("editor surface keys", () => {
  const counter = () => {
    let next = 0;
    return () => `surface-${++next}`;
  };

  test("keeps each mounted buffer on its surface", () => {
    const createKey = counter();
    const first = assignEditorSurfaceKeys(new Map(), ["a", "b"], createKey);
    const second = assignEditorSurfaceKeys(first, ["b", "a"], createKey);

    expect([...second]).toEqual([...first]);
  });

  test("hands an evicted buffer's surface to the newly mounted buffer", () => {
    const createKey = counter();
    const first = assignEditorSurfaceKeys(new Map(), ["a", "b"], createKey);
    const second = assignEditorSurfaceKeys(first, ["c", "b"], createKey);

    expect(second.get("b")).toBe(first.get("b"));
    expect(second.get("c")).toBe(first.get("a"));
    expect(second.has("a")).toBe(false);
  });

  test("creates a surface only when none is free", () => {
    const createKey = counter();
    const first = assignEditorSurfaceKeys(new Map(), ["a"], createKey);
    const second = assignEditorSurfaceKeys(first, ["a", "b"], createKey);

    expect(second.get("a")).toBe("surface-1");
    expect(second.get("b")).toBe("surface-2");
  });
});
