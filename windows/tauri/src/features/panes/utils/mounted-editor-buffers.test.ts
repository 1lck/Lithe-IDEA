import { describe, expect, test } from "bun:test";
import { reconcileMountedEditorBuffers } from "./mounted-editor-buffers";

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
