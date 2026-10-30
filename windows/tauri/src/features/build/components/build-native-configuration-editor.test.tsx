import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import { WindowsBuildProviderWorkspace, type BuildNativeConfiguration } from "../services/build-provider-workspace";
import { BuildNativeConfigurationController } from "../services/build-native-configuration-controller";
import type { buildCore } from "@/platform/build-core-api";
import * as inputControl from "@/ui/input";
// Initialize React's browser event feature detection with DOM globals present.
const restoreInitialDom = installHappyDom();
afterAll(restoreInitialDom);
const { createRoot } = await import("react-dom/client");
const { BuildNativeConfigurationEditor } = await import("./build-native-configuration-editor");

const instance = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", options: {} };
const source: BuildNativeConfiguration["sources"][number] = { id: "user", scope: "user", uri: "file:///C:/fixture/settings.xml", revision: "read-1", writable: true,
  rootElement: { name: "settings", namespace: "" }, fields: [{ id: "repository", kind: "directory", value: null, effectiveValue: "C:/inherited", effectiveSource: "default", path: ["repository"] }] };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}
function fixture() {
  let configuration: BuildNativeConfiguration = { format: "litheBuildConfiguration", version: 1, sources: [structuredClone(source),
    { ...structuredClone(source), id: "workspace", scope: "workspace", uri: "file:///C:/fixture/project.xml" }] };
  const calls: string[] = [], prepared = deferred<void>();
  let selected: typeof instance | undefined = instance, conflict = false, failingReads = false, projectTool = false;
  let prepareGate: Promise<boolean> | undefined;
  let edits: { sourceID: string; values: Record<string, unknown> } | undefined;
  const core = (async (command: string) => {
    if (command === "build.configurationPlan") return { plan: { provider: { method: command, params: {} } } };
    if (command === "build.decodeConfiguration") return { configuration: structuredClone(configuration) };
    throw new Error(`Unexpected command ${command}`);
  }) as typeof buildCore;
  const domain = new WindowsBuildProviderWorkspace("C:/fixture", { core, guard: () => () => {}, translate: createTranslator("en-US"),
    tools: async () => ({ manifest: { id: instance.pluginID }, pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state",
      tool: { executable: "C:/maven/tool" }, environment: {}, executesProjectCode: projectTool }),
    providers: { send: async <T,>() => { calls.push("read"); if (failingReads) throw new Error("readback failed"); return {} as T; }, stop: async () => {} },
    configurationFiles: {
      prepare: async (_target, _root, _id, _snapshot, change) => { calls.push("prepare"); edits = change; prepared.resolve(); return await prepareGate ?? true; },
      commit: async () => {
        calls.push("commit");
        if (conflict) throw Object.assign(new Error("disk changed"), { code: "build.configuration.conflict" });
        configuration = structuredClone(configuration);
        const target = configuration.sources.find(source => source.id === edits!.sourceID)!;
        target.revision += "-saved";
        for (const field of target.fields) if (Object.prototype.hasOwnProperty.call(edits!.values, field.id)) {
          field.value = edits!.values[field.id]; field.effectiveValue = field.value === null ? "C:/inherited" : "C:/actual-upstream";
        }
      },
      cancel: async () => { calls.push("cancel"); },
    },
  });
  const controller = new BuildNativeConfigurationController(domain, () => selected);
  return { controller, domain, calls, prepared,
    change: (text: string, id = "user") => { controller.set(id, "repository", { override: true, value: text }); },
    conflict: () => { conflict = true; }, failReads: (value = true) => { failingReads = value; }, projectTool: () => { projectTool = true; },
    holdPrepare: (promise: Promise<boolean>) => { prepareGate = promise; },
    readonly: () => { configuration.sources[0]!.writable = false; },
    fields: (fields: typeof source.fields) => { configuration.sources[0]!.fields = fields; },
    remove: () => { selected = undefined; domain.invalidate(instance); },
    edits: () => edits,
    dispose: async () => { controller.dispose(); await domain.dispose(); },
  };
}

test("source drafts distinguish inherited values, cancellation, and an explicit override", async () => {
  const f = fixture();
  try {
    await f.controller.read();
    expect(f.controller.snapshot().drafts.user?.repository).toEqual({ override: false, value: "C:/inherited" });
    await f.controller.save("user"); expect(f.calls).toEqual(["read"]);
    f.change("C:/draft"); f.controller.cancel("user"); await f.controller.save("user");
    expect(f.calls).toEqual(["read"]);
    f.change("C:/draft"); await f.controller.save("user");
    expect(f.calls).toEqual(["read", "prepare", "commit", "read", "cancel"]);
    expect(f.edits()).toMatchObject({ sourceID: "user", values: { repository: "C:/draft" } });
    expect(f.controller.snapshot().configuration?.sources[0]?.fields[0]?.effectiveValue).toBe("C:/actual-upstream");
  } finally { await f.dispose(); }
}, 5000);

test("saving one source retains the other source's draft while failed reloads require a new baseline", async () => {
  const f = fixture();
  try {
    await f.controller.read(); f.change("C:/user"); f.change("C:/workspace", "workspace"); await f.controller.save("user");
    expect(f.controller.edits("user")).toEqual({});
    expect(f.controller.edits("workspace")).toEqual({ repository: "C:/workspace" });
    f.failReads(); await f.controller.read();
    expect(f.controller.snapshot()).toMatchObject({ stale: true, phase: "failed", error: "readback failed" });
    // A failed reload must not silently make the old draft writable again.
    const calls = [...f.calls]; await f.controller.save("workspace");
    expect(f.calls).toEqual(calls);
    expect(f.controller.edits("workspace")).toEqual({ repository: "C:/workspace" });
  } finally { await f.dispose(); }
}, 5000);

test("a disk conflict retains its draft and input revocation stops a pending save before commit", async () => {
  const conflict = fixture();
  try {
    await conflict.controller.read(); conflict.change("C:/draft"); conflict.conflict(); await conflict.controller.save("user");
    expect(conflict.controller.snapshot().error).toContain("changed on disk");
    expect(conflict.controller.edits("user")).toEqual({ repository: "C:/draft" });
    expect(conflict.calls.filter(call => call === "read")).toHaveLength(1);
  } finally { await conflict.dispose(); }
  const f = fixture(), gate = deferred<boolean>();
  let saving: Promise<void> | undefined;
  try {
    await f.controller.read(); f.change("C:/draft"); f.holdPrepare(gate.promise);
    saving = f.controller.save("user"); await f.prepared.promise;
    f.domain.invalidate(instance); gate.resolve(true); await saving;
    expect(f.controller.snapshot().stale).toBe(true);
    expect(f.calls).not.toContain("commit");
    expect(f.controller.edits("user")).toEqual({ repository: "C:/draft" });
  } finally { gate.resolve(true); await saving; await f.dispose(); }
}, 5000);

test("readback failure after a native commit retains the draft and blocks another save until reload", async () => {
  const f = fixture();
  try {
    await f.controller.read(); f.change("C:/draft"); f.failReads(); await f.controller.save("user");
    expect(f.controller.snapshot()).toMatchObject({ saving: false, stale: true, error: "readback failed" });
    expect(f.controller.edits("user")).toEqual({ repository: "C:/draft" });
    expect(f.calls).toContain("commit");
    const count = f.calls.length; await f.controller.save("user"); expect(f.calls).toHaveLength(count);
    f.failReads(false); await f.controller.read();
    expect(f.controller.snapshot().stale).toBe(false);
    expect(f.controller.edits("user")).toEqual({});
    expect(f.controller.snapshot().configuration?.sources[0]?.fields[0]?.effectiveValue).toBe("C:/actual-upstream");
  } finally { await f.dispose(); }
}, 5000);

test("false booleans, empty lists and removal of an override remain distinct native edits", async () => {
  const f = fixture();
  f.fields([{ id: "flag", kind: "boolean", value: true, effectiveValue: true, effectiveSource: "user", path: ["flag"] },
    { id: "items", kind: "stringList", value: ["saved"], effectiveValue: ["saved"], effectiveSource: "user", path: ["items"], itemElement: "item" }]);
  try {
    await f.controller.read();
    f.controller.set("user", "flag", { value: false }); f.controller.set("user", "items", { value: [] });
    expect(f.controller.edits("user")).toEqual({ flag: false, items: [] });
    f.controller.set("user", "flag", { override: false });
    expect(f.controller.edits("user")).toEqual({ flag: null, items: [] });
    expect(f.calls).toEqual(["read"]);
  } finally { await f.dispose(); }
}, 5000);

test("explicit overrides of absent effective values store typed empty values without inventing inherited defaults", async () => {
  const f = fixture();
  f.fields((["boolean", "stringList", "text"] as const).map(kind => ({ id: kind, kind, value: null, effectiveValue: null,
    effectiveSource: "unset", path: [kind], ...(kind === "stringList" ? { itemElement: "item" } : {}) })));
  try {
    await f.controller.read();
    expect(f.controller.edits("user")).toEqual({});
    for (const id of ["boolean", "stringList", "text"]) f.controller.set("user", id, { override: true });
    expect(f.controller.edits("user")).toEqual({ boolean: false, stringList: [], text: "" });
    expect(f.calls).toEqual(["read"]);
  } finally { await f.dispose(); }
}, 5000);

test("read-only sources and a removed workspace never start native writes", async () => {
  const f = fixture(); f.readonly();
  try {
    await f.controller.read(); f.change("C:/forbidden"); await f.controller.save("user");
    expect(f.controller.edits("user")).toEqual({});
    expect(f.calls).toEqual(["read"]);
    f.remove(); await f.controller.read(); await f.controller.save("workspace");
    expect(f.calls).toEqual(["read"]);
  } finally { await f.dispose(); }
}, 5000);

let restoreDom: () => void, root: Root, container: HTMLDivElement;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined, previousAnimations: PropertyDescriptor | undefined;
let restoreInput: () => void;
beforeEach(() => {
  restoreDom = installHappyDom(); previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT; actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousAnimations = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "getAnimations");
  Object.defineProperty(HTMLElement.prototype, "getAnimations", { configurable: true, value: () => [] });
  // Other files may initialize React before DOM globals exist. Match the
  // existing settings/changelist tests: stub only the native input boundary,
  // preserving the editor's real change handler and controlled value.
  const input = spyOn(inputControl, "default").mockImplementation((({ onChange, value, disabled, "aria-label": label }) =>
    <input value={value} disabled={disabled} aria-label={label}
      onInput={event => onChange?.({ ...event, target: event.currentTarget })} />) as typeof inputControl.default);
  restoreInput = () => input.mockRestore();
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => {
  try { await act(async () => root.unmount()); }
  finally {
    container.remove(); restoreInput();
    if (previousAnimations) Object.defineProperty(HTMLElement.prototype, "getAnimations", previousAnimations); else Reflect.deleteProperty(HTMLElement.prototype, "getAnimations");
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT; else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
async function render(f: ReturnType<typeof fixture>, choosePath?: (directory: boolean) => Promise<string | null>) {
  await act(async () => root.render(<LocaleProvider language="en-US"><BuildNativeConfigurationEditor controller={f.controller} title="Fixture" choosePath={choosePath} /></LocaleProvider>));
}
function button(text: string) { return [...container.querySelectorAll<HTMLButtonElement>("button")].find(button => button.textContent === text)!; }

test("opening settings is read-only, explicit Save reads back, and remount retains the draft", async () => {
  const f = fixture();
  try {
    await render(f);
    expect(f.calls).toEqual(["read"]);
    expect(container.textContent).toContain("file:///C:/fixture/settings.xml");
    expect(container.querySelector<HTMLInputElement>('input[aria-label="repository"]')?.value).toBe("C:/inherited");
    expect(button("Save").disabled).toBe(true);
    await act(async () => container.querySelector<HTMLElement>('[role="checkbox"][aria-label="repository Override"]')!.closest("label")!.click());
    await act(async () => {
      const input = container.querySelector<HTMLInputElement>('input[aria-label="repository"]')!;
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "C:/draft");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(f.controller.edits("user")).toEqual({ repository: "C:/draft" });
    await act(async () => root.render(null)); await render(f);
    expect(container.querySelector<HTMLInputElement>('input[aria-label="repository"]')?.value).toBe("C:/draft");
    expect(f.calls).toEqual(["read"]);
    await act(async () => button("Save").click());
    expect(container.textContent).toContain("C:/actual-upstream");
    expect(button("Save").disabled).toBe(true);
  } finally { await act(async () => { await f.dispose(); }); }
}, 5000);

test("project tools require an explicit read and an old picker reply cannot edit a reloaded baseline", async () => {
  const f = fixture(), picker = deferred<string | null>(); f.projectTool();
  try {
    await render(f, () => picker.promise);
    expect(f.calls).toEqual([]);
    expect(button("Read using project tool")).toBeDefined();
    await act(async () => button("Read using project tool").click());
    expect(f.calls).toEqual(["read"]);
    await act(async () => f.change("C:/draft"));
    await act(async () => button("Choose").click());
    await act(async () => button("Reload").click());
    await act(async () => picker.resolve("C:/late-picker"));
    expect(f.controller.snapshot().drafts.user?.repository).toMatchObject({ override: false, value: "C:/inherited" });
    expect(f.calls).toEqual(["read", "read"]);
  } finally { picker.resolve(null); await act(async () => { await f.dispose(); }); }
}, 5000);
