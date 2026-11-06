import { beforeAll, describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/editor/workbench-state-v1.json";
import { executeCoreRuleSync } from "@/core/core-rules";
import { loadCoreRulesForTests } from "@/test-utils/core-rules";
import type { PaneGroup } from "../types/pane.types";
import { reduceWorkbenchGroups, WORKBENCH_STATE_REDUCE_COMMAND } from "./workbench-state";

// The same fixture drives the Rust tests in lithe-core-rules and lithe-core and the macOS
// adapter test, so every host sees one definition of group membership. Here it runs through the
// real wasm build that the app ships.
beforeAll(loadCoreRulesForTests);

describe("workbench state rules (shared fixture through wasm)", () => {
  for (const entry of fixture.cases) {
    test(entry.name, () => {
      const result = executeCoreRuleSync(WORKBENCH_STATE_REDUCE_COMMAND, {
        state: entry.state,
        action: entry.action,
      });
      expect(result).toEqual({
        state: entry.expected.state,
        removedGroupIds: entry.expected.removedGroupIds,
      });
    });
  }

  test("malformed requests fail with the Core error code", () => {
    expect(() =>
      executeCoreRuleSync(WORKBENCH_STATE_REDUCE_COMMAND, { action: { kind: "bogus" } }),
    ).toThrow(expect.objectContaining({ code: "invalid_request" }));
  });
});

describe("pane group adapter", () => {
  const group = (overrides: Partial<PaneGroup>): PaneGroup => ({
    id: "g1",
    type: "group",
    bufferIds: [],
    activeBufferId: null,
    ...overrides,
  });

  test("keeps fields Core does not own and falls back to tab order for a missing MRU", () => {
    const { groups } = reduceWorkbenchGroups(
      [group({ bufferIds: ["a", "b"], activeBufferId: "a", locked: true })],
      { kind: "open", group: "g1", member: "c", activate: false },
    );
    expect(groups).toEqual([
      {
        id: "g1",
        type: "group",
        bufferIds: ["a", "b", "c"],
        activeBufferId: "a",
        mruBufferIds: ["a", "b", "c"],
        pinnedBufferIds: [],
        previewBufferId: null,
        locked: true,
      },
    ]);
  });

  test("returns the same object when Core changes nothing", () => {
    const original = group({
      bufferIds: ["a", "b"],
      activeBufferId: "a",
      mruBufferIds: ["a", "b"],
      pinnedBufferIds: [],
      previewBufferId: null,
    });
    const { groups } = reduceWorkbenchGroups([original], {
      kind: "reorder",
      group: "g1",
      fromIndex: 0,
      toIndex: 9,
    });
    expect(groups[0]).toBe(original);
  });

  test("reports removed groups and drops them from the result", () => {
    const { groups, removedGroupIds } = reduceWorkbenchGroups(
      [
        group({ id: "g1", bufferIds: ["a"], activeBufferId: "a" }),
        group({ id: "g2", bufferIds: ["b"], activeBufferId: "b" }),
      ],
      { kind: "close", group: "g1", member: "a", emptyGroups: "remove" },
    );
    expect(removedGroupIds).toEqual(["g1"]);
    expect(groups.map((entry) => entry.id)).toEqual(["g2"]);
  });
});
