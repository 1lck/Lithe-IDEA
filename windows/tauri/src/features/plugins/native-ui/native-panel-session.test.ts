import { expect, test } from "bun:test";
import { nativeUIValidator } from "./native-ui-core";
import { NativePanelStateStore } from "./native-panel-state";
import { NativePanelSession, nativeRows } from "./native-panel-session";
import type { NativeNode, NativePanelIdentity, NativePanelPort, NativeUI } from "./native-ui.types";
import nativeControls from "../../../../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json";
import type { NativePanelState } from "./native-panel-session";

const identity = (packageIdentity = "bytes-a"): NativePanelIdentity => ({
  pluginId: "fixture.native",
  packageIdentity,
  hostWindowId: "main",
  workspaceId: "workspace-a",
  windowId: "fixture.native.panel",
  panelId: "panel",
});
const tree = (count = 3): NativeNode[] =>
  Array.from({ length: count }, (_, index) => ({
    id: `node-${index}`,
    label: `Node ${index}`,
    children: index === 0 ? [{ id: "child-0", label: "Child 0" }] : undefined,
  }));
const ui: NativeUI = {
  schemaVersion: 1,
  id: "panel",
  kind: "tree",
  nodes: tree(),
  actions: [],
  toolbar: [],
  contextMenu: [],
};
const form: NativeUI = {
  schemaVersion: 1,
  id: "form",
  kind: "form",
  nodes: [],
  controls: [{ id: "name", kind: "input", label: "Name", value: "initial", enabled: true }],
  buttons: [],
  actions: [],
  toolbar: [],
  contextMenu: [],
};
const fixture = (declaration: NativeUI, port: Partial<NativePanelPort> = {}) => {
  const published: NativePanelState[] = [];
  const session = new NativePanelSession(
    identity(),
    declaration,
    { validate: async (_ui, data) => (data as { nodes: NativeNode[] }).nodes, ...port },
    new NativePanelStateStore(),
    (state) => published.push(state),
  );
  return [session, published] as const;
};
function makeSession() {
  return fixture(ui);
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

test("tree rows preserve stable depth, expand state and bounded keyboard order", async () => {
  const [session] = makeSession();
  try {
    await session.open();
    expect(session.state.rows.map((row) => row.node.id)).toEqual(["node-0", "node-1", "node-2"]);
    session.select("node-0");
    expect(session.navigate("ArrowRight")).toBe("node-0");
    expect(session.state.rows.map((row) => row.node.id)).toEqual([
      "node-0",
      "child-0",
      "node-1",
      "node-2",
    ]);
    expect(session.navigate("ArrowDown")).toBe("child-0");
    expect(session.navigate("ArrowLeft")).toBe("node-0");
    expect(nativeRows(tree(600), []).length).toBe(600);
  } finally {
    session.close();
  }
}, 1000);

test("form drafts are isolated by complete panel identity and invalid restored values are discarded", async () => {
  const store = new NativePanelStateStore();
  const first = new NativePanelSession(
    identity("bytes-a"),
    form,
    { validate: async (_ui, data) => (data as { nodes: NativeNode[] }).nodes },
    store,
    () => {},
  );
  await first.open();
  await first.edit("name", "中文 😀", first.state.epoch);
  first.close();
  const replacement = new NativePanelSession(
    identity("bytes-b"),
    form,
    { validate: async (_ui, data) => (data as { nodes: NativeNode[] }).nodes },
    store,
    () => {},
  );
  await replacement.open();
  try {
    expect(replacement.state.values.name).toBe("initial");
  } finally {
    replacement.close();
  }
}, 1000);

test("a late edit validation cannot restore an older draft after a newer edit", async () => {
  const first = deferred<NativeNode[]>();
  let calls = 0;
  const [session] = fixture(form, {
    validate: async (_ui, data, signal) => {
      const nodes = (data as { nodes: NativeNode[] }).nodes;
      if (++calls === 1) return nodes;
      if (calls === 2) return first.promise;
      signal.throwIfAborted();
      return nodes;
    },
  });
  try {
    await session.open();
    const oldEdit = session.edit("name", "old", session.state.epoch, true);
    const newEdit = session.edit("name", "new", session.state.epoch, true);
    await newEdit;
    first.resolve([]);
    await oldEdit;
    expect(session.state.values.name).toBe("new");
  } finally {
    first.resolve([]);
    session.close();
  }
}, 1000);

test("closing a panel cancels its source request and publishes no late result", async () => {
  const source = deferred<unknown>();
  const published: NativePanelState[] = [];
  const session = new NativePanelSession(
    identity(),
    { ...ui, source: { buildSystemID: "maven", function: "nodes" } },
    {
      validate: async (_ui, data) => (data as { nodes: NativeNode[] }).nodes,
      functions: { load: async () => source.promise, invoke: async () => {} },
    },
    new NativePanelStateStore(),
    (state) => published.push(state),
  );
  const opening = session.open();
  session.close();
  source.resolve({ nodes: tree() });
  await opening;
  expect(session.state.phase).toBe("closed");
  expect(published[published.length - 1]?.phase).toBe("loading");
}, 1000);

test("Core rejection is surfaced through the typed adapter and dynamic actions stay unavailable without functions", async () => {
  const validator = nativeUIValidator(async () => ({
    status: "rejected",
    error: { code: "plugin.ui.invalidData", message: "invalid" },
  }));
  await expect(validator(ui, { nodes: [] }, new AbortController().signal)).rejects.toMatchObject({
    message: "pluginNative.invalidData",
  });
  const [session] = fixture({
    ...ui,
    source: { buildSystemID: "maven", function: "nodes" },
    actions: [{ id: "refresh", title: "Refresh", kind: "refresh", requiresSelection: false }],
  });
  try {
    await session.open();
    expect(session.state.error).toBe("pluginNative.unavailable");
  } finally {
    session.close();
  }
}, 1000);

test("the shared native-controls fixture exercises the complete form control set", () => {
  const window = nativeControls.ui.toolWindows.find((candidate) => candidate.native)
    ?.native as unknown as NativeUI;
  expect(window.schemaVersion).toBe(1);
  expect(window.kind).toBe("form");
  expect(window.layout?.columns).toBe(12);
  expect(window.controls?.map((control) => control.kind)).toEqual(
    expect.arrayContaining([
      "input",
      "search",
      "editor",
      "select",
      "segmented",
      "checkbox",
      "stepper",
    ]),
  );
  expect(window.controls?.filter((control) => control.enabled === false).length).toBeGreaterThan(0);
  expect(window.buttons?.length).toBeGreaterThan(0);
});

test("form buttons and refresh validate uncommitted fields before any function receives their values", async () => {
  let rejectDraft = false;
  let invokes = 0;
  let loads = 0;
  const declaration: NativeUI = {
    ...form,
    source: { buildSystemID: "fixture", function: "load" },
    actions: [
      { id: "apply", title: "Apply", kind: "invoke", function: "apply", requiresSelection: false },
    ],
  };
  const [session] = fixture(declaration, {
    // Core's rejection is controlled here; the host must not duplicate its
    // field rules or send a rejected draft to the provider first.
    validate: async (_ui, data) => {
      if (rejectDraft) throw new Error("pluginNative.invalidData");
      return (data as { nodes: NativeNode[] }).nodes;
    },
    functions: {
      load: async () => {
        loads++;
        return { nodes: [] };
      },
      invoke: async () => {
        invokes++;
      },
    },
  });
  try {
    await session.open();
    const initialLoads = loads;
    await session.edit("name", "uncommitted draft", session.state.epoch);
    rejectDraft = true;
    await session.perform("apply", session.state.epoch);
    expect(invokes).toBe(0);
    expect(loads).toBe(initialLoads);
    expect(session.state.error).toBe("pluginNative.invalidData");
    await session.refresh();
    expect(loads).toBe(initialLoads);
    expect(session.state.values.name).toBe("uncommitted draft");
  } finally {
    session.close();
  }
}, 1000);

test("refresh retries a transient source failure without resetting selection or expansion", async () => {
  let rejectSource = false;
  const refresh: NativeUI["actions"][number] = {
    id: "refresh",
    title: "Refresh",
    kind: "refresh",
    requiresSelection: false,
  };
  const [session] = fixture(
    { ...ui, source: { buildSystemID: "fixture", function: "load" }, actions: [refresh] },
    {
      functions: {
        load: async () => {
          if (rejectSource) throw new Error("provider unavailable");
          return { nodes: tree() };
        },
        invoke: async () => {},
      },
    },
  );
  try {
    await session.open();
    session.select("node-0");
    session.toggle("node-0");
    session.select("child-0");
    rejectSource = true;
    await session.perform("refresh", session.state.epoch);
    expect(session.state.error).toBe("pluginNative.failed");
    expect(session.canPerform(refresh)).toBe(true);
    rejectSource = false;
    await session.perform("refresh", session.state.epoch);
    expect(session.state.error).toBeUndefined();
    expect(session.state.selection).toBe("child-0");
    expect(session.state.expanded).toEqual(["node-0"]);
  } finally {
    session.close();
  }
}, 1000);

test("reset rejects the old field epoch and cancelled action validation cannot later invoke", async () => {
  const validation = deferred<NativeNode[]>();
  let holdValidation = false;
  let invokes = 0;
  const [session] = fixture(
    {
      ...form,
      source: { buildSystemID: "fixture", function: "load" },
      actions: [
        {
          id: "apply",
          title: "Apply",
          kind: "invoke",
          function: "apply",
          requiresSelection: false,
        },
      ],
    },
    {
      validate: async (_ui, data) =>
        holdValidation ? validation.promise : (data as { nodes: NativeNode[] }).nodes,
      functions: {
        load: async () => ({ nodes: [] }),
        invoke: async () => {
          invokes++;
        },
      },
    },
  );
  try {
    await session.open();
    const oldEpoch = session.state.epoch;
    await session.edit("name", "old draft", oldEpoch);
    holdValidation = true;
    const action = session.perform("apply", oldEpoch);
    holdValidation = false;
    await session.reset();
    validation.resolve([]);
    await action;
    expect(await session.edit("name", "late blur", oldEpoch, true)).toBe(false);
    expect(invokes).toBe(0);
    expect(session.state.values.name).toBe("initial");
  } finally {
    validation.resolve([]);
    session.close();
  }
}, 1000);

test("saved panel drafts share the plugin window workspace budget without replacing a valid snapshot on rejection", () => {
  const store = new NativePanelStateStore();
  const first = identity();
  const second = { ...first, panelId: "another-panel" };
  const large = { expanded: [], values: { text: "x".repeat(40 * 1024) } };
  const small = { expanded: [], values: { text: "kept" } };
  expect(store.write(first, large)).toBe(true);
  expect(store.write(second, small)).toBe(true);
  expect(store.write(second, large)).toBe(false);
  expect(store.read(second)).toEqual(small);
  expect(store.write({ ...second, workspaceId: "other-workspace" }, large)).toBe(true);
  store.remove(first);
  expect(store.write(second, large)).toBe(true);
});
