import { describe, expect, test } from "bun:test";
import {
  buildSystemViewId,
  parseBuildSystemViewId,
  useBuildSystemsStore,
} from "./build-systems-store";
import type { BuildView } from "./build-systems-types";

/**
 * Store tests for the build tool-window display state: grouping, selection
 * preservation, request-sequence guards, plugin revocation, and instance
 * selection validation. Pure state transitions with no timers and no host
 * calls.
 */

function view(generation: number, roots: string[], selectedIssue = false): BuildView {
  return {
    generation,
    workspaceRoot: "C:/work/demo",
    instances: roots.map((root) => ({
      pluginID: "dev.lithe.fixture.build-static-file",
      buildSystemID: "cargo",
      displayName: "Cargo",
      root,
      markers: ["Cargo.toml"],
      modelSource: "static",
      model: { projects: [{ name: "fixture-app", path: root }] },
      stale: false,
      syncDigest: null,
      optionFingerprint: "fp",
      options: [],
    })),
    issues: selectedIssue ? [{ kind: "shadowed", pluginID: "p2", by: "p1" }] : [],
  };
}

const VIEW_ID = buildSystemViewId("dev.lithe.fixture.build-static-file", "cargo");
const request = (sequence: number, revocationEpoch = 0) => ({
  sequence,
  revocationEpoch,
});

describe("build systems store", () => {
  test("groups instances of one build system into a single window", () => {
    useBuildSystemsStore.getState().actions.reset();
    useBuildSystemsStore.getState().actions.applyView(view(1, ["a", "b"]), request(1));

    const state = useBuildSystemsStore.getState();
    expect(Object.keys(state.windows)).toEqual([VIEW_ID]);
    expect(state.windows[VIEW_ID]!.instances.map((instance) => instance.root)).toEqual(["a", "b"]);
    expect(state.windows[VIEW_ID]!.selectedRoot).toBe("a");
    expect(state.status).toBe("ready");
  });

  test("the instance selection survives refreshes and falls back when removed", () => {
    useBuildSystemsStore.getState().actions.reset();
    useBuildSystemsStore.getState().actions.applyView(view(1, ["a", "b"]), request(1));
    useBuildSystemsStore.getState().actions.selectInstance(VIEW_ID, "b");
    expect(useBuildSystemsStore.getState().windows[VIEW_ID]!.selectedRoot).toBe("b");

    useBuildSystemsStore.getState().actions.applyView(view(2, ["a", "b"]), request(2));
    expect(useBuildSystemsStore.getState().windows[VIEW_ID]!.selectedRoot).toBe("b");

    useBuildSystemsStore.getState().actions.applyView(view(3, ["b"]), request(3));
    expect(useBuildSystemsStore.getState().windows[VIEW_ID]!.selectedRoot).toBe("b");

    useBuildSystemsStore.getState().actions.applyView(view(4, ["c"]), request(4));
    expect(useBuildSystemsStore.getState().windows[VIEW_ID]!.selectedRoot).toBe("c");
  });

  test("an unknown instance root is not selectable", () => {
    useBuildSystemsStore.getState().actions.reset();
    useBuildSystemsStore.getState().actions.applyView(view(1, ["a"]), request(1));

    useBuildSystemsStore.getState().actions.selectInstance(VIEW_ID, "not-a-root");
    expect(useBuildSystemsStore.getState().windows[VIEW_ID]!.selectedRoot).toBe("a");
  });

  test("a workspace change discards the previous view", () => {
    useBuildSystemsStore.getState().actions.reset();
    useBuildSystemsStore.getState().actions.applyView(view(2, ["a"]), request(2));

    const switched = { ...view(1, ["b"]), workspaceRoot: "C:/work/other" };
    useBuildSystemsStore.getState().actions.applyView(switched, request(3));

    const state = useBuildSystemsStore.getState();
    expect(state.generation).toBe(2);
    expect(state.windows[VIEW_ID]!.instances[0]!.root).toBe("a");
  });

  test("out-of-order responses are dropped by request sequence", () => {
    useBuildSystemsStore.getState().actions.reset();
    // Sequence 2 applies first.
    useBuildSystemsStore.getState().actions.applyView(view(5, ["new"]), request(2));
    // Sequence 1 is a late response and must not overwrite it.
    useBuildSystemsStore.getState().actions.applyView(view(4, ["old"]), request(1));

    const state = useBuildSystemsStore.getState();
    expect(state.generation).toBe(5);
    expect(state.windows[VIEW_ID]!.instances[0]!.root).toBe("new");
  });

  test("a late failure never clobbers a newer applied view", () => {
    useBuildSystemsStore.getState().actions.reset();
    const { beginRequest, applyView, fail } = useBuildSystemsStore.getState().actions;
    const first = beginRequest();
    applyView(view(3, ["a"]), first);
    const second = beginRequest();
    applyView(view(4, ["b"]), second);
    fail("late boom", first);

    const state = useBuildSystemsStore.getState();
    expect(state.status).toBe("ready");
    expect(state.error).toBeNull();
    expect(state.windows[VIEW_ID]!.instances[0]!.root).toBe("b");
  });

  test("dropPlugin removes that plugin's windows and issues only", () => {
    useBuildSystemsStore.getState().actions.reset();
    const otherInstance = {
      pluginID: "dev.lithe.other",
      buildSystemID: "gradle",
      displayName: "Gradle",
      root: "a",
      markers: [],
      modelSource: "static" as const,
      model: null,
      stale: false,
      syncDigest: null,
      optionFingerprint: null,
      options: [],
    };
    const mixed = view(1, ["a"], true);
    useBuildSystemsStore.getState().actions.applyView(
      {
        ...mixed,
        instances: [...mixed.instances, otherInstance],
        issues: [
          ...mixed.issues,
          {
            kind: "rejected" as const,
            pluginID: "dev.lithe.other",
            error: { code: "x", message: "y" },
          },
        ],
      },
      request(1),
    );

    useBuildSystemsStore.getState().actions.dropPlugin("dev.lithe.fixture.build-static-file");

    const state = useBuildSystemsStore.getState();
    expect(Object.keys(state.windows)).toEqual([buildSystemViewId("dev.lithe.other", "gradle")]);
    expect(
      state.issues.every((issue) => issue.pluginID !== "dev.lithe.fixture.build-static-file"),
    ).toBe(true);
  });

  test("issues ride along with the view", () => {
    useBuildSystemsStore.getState().actions.reset();
    useBuildSystemsStore.getState().actions.applyView(view(1, ["a"], true), request(1));
    expect(useBuildSystemsStore.getState().issues).toEqual([
      { kind: "shadowed", pluginID: "p2", by: "p1" },
    ]);
  });

  test("a response crossing plugin revocation cannot revive that plugin", () => {
    useBuildSystemsStore.getState().actions.reset();
    const started = useBuildSystemsStore.getState().actions.beginRequest();

    useBuildSystemsStore.getState().actions.dropPlugin("dev.lithe.fixture.build-static-file");
    useBuildSystemsStore.getState().actions.applyView(view(1, ["late"]), started);

    const state = useBuildSystemsStore.getState();
    expect(state.windows[VIEW_ID]).toBeUndefined();
    expect(state.status).toBe("ready");
  });

  test("revocation filters only its plugin from a late complete view", () => {
    useBuildSystemsStore.getState().actions.reset();
    const started = useBuildSystemsStore.getState().actions.beginRequest();
    const other = {
      ...view(1, ["revoked"]).instances[0]!,
      pluginID: "dev.lithe.other",
      buildSystemID: "gradle",
      displayName: "Gradle",
      root: "kept",
    };

    useBuildSystemsStore.getState().actions.dropPlugin("dev.lithe.fixture.build-static-file");
    useBuildSystemsStore
      .getState()
      .actions.applyView(
        { ...view(1, ["revoked"]), instances: [...view(1, ["revoked"]).instances, other] },
        started,
      );

    const state = useBuildSystemsStore.getState();
    expect(state.windows[VIEW_ID]).toBeUndefined();
    expect(state.windows[buildSystemViewId("dev.lithe.other", "gradle")]?.instances[0]?.root).toBe(
      "kept",
    );
  });

  test("a failure crossing revocation cannot replace the remaining plugin state", () => {
    useBuildSystemsStore.getState().actions.reset();
    const current = useBuildSystemsStore.getState().actions.beginRequest();
    useBuildSystemsStore.getState().actions.applyView(view(1, ["a"]), current);
    const late = useBuildSystemsStore.getState().actions.beginRequest();

    useBuildSystemsStore.getState().actions.dropPlugin("dev.lithe.unrelated-disabled-plugin");
    useBuildSystemsStore.getState().actions.fail("late failure", late);

    const state = useBuildSystemsStore.getState();
    expect(state.status).toBe("ready");
    expect(state.error).toBeNull();
    expect(state.windows[VIEW_ID]).toBeDefined();
  });

  test("view ids round-trip through the parser", () => {
    expect(parseBuildSystemViewId(VIEW_ID)).toEqual({
      pluginId: "dev.lithe.fixture.build-static-file",
      buildSystemId: "cargo",
    });
    expect(parseBuildSystemViewId("maven")).toBeNull();
    expect(parseBuildSystemViewId("build-system:only-one-part")).toBeNull();
    expect(parseBuildSystemViewId("build-system:a:")).toBeNull();
    expect(parseBuildSystemViewId("build-system::b")).toBeNull();
  });
});
