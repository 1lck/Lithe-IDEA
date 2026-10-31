import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as virtualization from "@tanstack/react-virtual";
import { act, useSyncExternalStore } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { BuildWorkspaceController } from "../services/build-workspace-controller";
import { WindowsBuildProviderWorkspace, type BuildModel } from "../services/build-provider-workspace";
import type { WindowsBuildCatalog } from "@/platform/build-provider-platform";
import type { buildCore } from "@/platform/build-core-api";
import { BuildPaneContent } from "./build-pane";
import { BuildOutputContent } from "./build-output-pane";
import type { BuildSourceNavigation } from "./build-results-content";
import type { BuildTestResults } from "../services/build-results";
import * as dialogControl from "@/ui/dialog";
import * as inputControl from "@/ui/input";

const catalog: WindowsBuildCatalog = { detection: { instances: [{ id: "example:root", pluginID: "dev.example.build", buildSystemID: "example",
  root: ".", displayName: "Example Build", options: {}, optionFingerprint: "default", droppedOptions: [], modelSource: "provider" }],
  rejected: [], shadowed: [] }, plugins: [{ manifest: { id: "dev.example.build" } }], document: { version: 1, systems: {} } };
const model: BuildModel = { projects: [{ id: "app", name: "App", path: "app", properties: {} }], targets: [], contentRoots: [], optionValues: {},
  tasks: [{ id: "upstream:compile", projectID: "app", name: "Upstream compile", template: "compile", execution: "task", path: "app", properties: {} }] };
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}
function fixture() {
  type Ports = ConstructorParameters<typeof WindowsBuildProviderWorkspace>[1];
  type Request = Parameters<Ports["providers"]["send"]>[1];
  const sent: Request[] = [];
  const entered = deferred<void>();
  let pending: Promise<unknown> | undefined, decodedModel = structuredClone(model), failedDetection = false, detected = structuredClone(catalog);
  let onProvider: ((request: Request) => void) | undefined;
  let report: BuildTestResults = { success: false, summary: { total: 1, passed: 0, failed: 1, errors: 0, skipped: 0 },
    tests: [{ suite: "ExampleTest", case: "fails", project: "app", status: "failed", message: "Expected upstream value", path: "app/ExampleTest.java", line: 9, invocations: 1 }] };
  const core = (async (command: string, _manifest: unknown, _system: string, request: Record<string, unknown>) => {
    if (command === "build.syncFingerprint") return { sync: { fingerprint: "unchanged", watch: ["project.marker", "app/project.marker"] } };
    if (command.endsWith("Plan")) return { plan: { provider: { method: command, params: request } } };
    if (command === "build.decodeModel") return { model: decodedModel };
    if (command === "build.decodeDiagnostics") return { diagnostics: [{ path: "app/Main.java", line: 7, column: 2, severity: "warning", message: "Upstream warning" }] };
    if (command === "build.decodeTestDiscovery") return { discovery: { tests: [{ id: "opaque:app", suite: "ExampleTest", case: "fails", project: model.projects[0] }] } };
    if (command === "build.decodeTestResults") return { results: report };
    if (command === "build.decodeDependencies") return { dependencies: { project: "app", truncated: false, dependencies: [
      { name: "Upstream library", version: "1.0", children: [{ name: "Nested library", children: [] }] },
    ] } };
    throw new Error(`Unexpected command ${command}`);
  }) as typeof buildCore;
  const domain = new WindowsBuildProviderWorkspace("C:/work", { core, translate: createTranslator("en-US"), guard: () => () => {},
    tools: async () => ({ manifest: { id: "dev.example.build" }, pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state",
      tool: { executable: "C:/tool" }, environment: {}, executesProjectCode: false }),
    providers: { send: async <T,>(_target: unknown, request: Request) => {
      sent.push(request); entered.resolve(); onProvider?.(request);
      return (pending ? await pending : { exitCode: 0, output: "upstream output\n", ...(request.method === "build.testPlan" ? { testResults: { version: 1 } } : {}) }) as T;
    }, stop: async () => {} },
  });
  const controller = new BuildWorkspaceController("C:/work", { domain, guard: () => () => {}, detect: async () => {
    if (failedDetection) throw new Error("Detection rejected");
    return structuredClone(detected);
  } });
  return { domain, controller, sent, entered, hold: (gate?: Promise<unknown>) => { pending = gate; },
    report: (value: BuildTestResults) => { report = value; }, onProvider: (callback: (request: Request) => void) => { onProvider = callback; },
    model: (value: BuildModel) => { decodedModel = value; }, failDetection: () => { failedDetection = true; },
    manifest: (value: Record<string, unknown>) => { detected.plugins = [{ manifest: value }]; } };
}

let restoreDom: () => void, root: Root, container: HTMLDivElement;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined, previousAnimations: PropertyDescriptor | undefined;
let previousPane: Pick<ReturnType<typeof useUIState.getState>, "bottomPaneActiveTab" | "isBottomPaneVisible" | "activeRightSidebarView" | "isRightSidebarVisible">;
beforeEach(() => {
  restoreDom = installHappyDom(); previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT; actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousAnimations = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "getAnimations");
  Object.defineProperty(HTMLElement.prototype, "getAnimations", { configurable: true, value: () => [] });
  const state = useUIState.getState();
  previousPane = { bottomPaneActiveTab: state.bottomPaneActiveTab, isBottomPaneVisible: state.isBottomPaneVisible,
    activeRightSidebarView: state.activeRightSidebarView, isRightSidebarVisible: state.isRightSidebarVisible };
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => {
  try { await act(async () => root.unmount()); }
  finally {
    container.remove(); useUIState.setState(previousPane);
    if (previousAnimations) Object.defineProperty(HTMLElement.prototype, "getAnimations", previousAnimations);
    else Reflect.deleteProperty(HTMLElement.prototype, "getAnimations");
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT; else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    restoreDom();
  }
});
function Surface({ controller, language, onNavigate }: { controller: BuildWorkspaceController; language: "en-US" | "zh-CN"; onNavigate?: BuildSourceNavigation }) {
  const snapshot = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  return <LocaleProvider language={language}><BuildPaneContent controller={controller} snapshot={snapshot} />
    <BuildOutputContent domain={controller.domain} operationID={snapshot.operationID} onNavigate={onNavigate} /></LocaleProvider>;
}
async function render(controller: BuildWorkspaceController, language: "en-US" | "zh-CN" = "en-US", onNavigate?: BuildSourceNavigation) {
  await act(async () => { root.render(<Surface controller={controller} language={language} onNavigate={onNavigate} />); });
}
function button(label: string) { return [...container.querySelectorAll<HTMLButtonElement>("button")].find(button => button.textContent === label || button.getAttribute("aria-label") === label)!; }

test("Build loads only on explicit action, runs the selected model task, and preserves output after pane remount", async () => {
  const f = fixture();
  try {
    await f.controller.refresh(); await render(f.controller);
    expect(f.sent).toHaveLength(0);
    await act(async () => button("Load project model").click());
    expect(f.sent.map(request => request.method)).toEqual(["build.modelPlan"]);
    expect(button("Upstream compile")).toBeDefined();
    await act(async () => button("Upstream compile").click());
    expect(f.sent[1]!.params).toMatchObject({ task: "compile", project: { id: "app", path: "app" } });
    expect(useUIState.getState()).toMatchObject({ bottomPaneActiveTab: "build", isBottomPaneVisible: true });
    expect(container.textContent).toContain("upstream output");
    await act(async () => root.render(null)); await render(f.controller, "zh-CN");
    expect(container.textContent).toContain("构建输出");
    expect(container.textContent).toContain("已成功");
    expect(container.textContent).toContain("upstream output");
    expect(f.sent).toHaveLength(2);
  } finally { await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("Stop cancels the current preparation and late progress cannot revive its output", async () => {
  const f = fixture(), gate = deferred<unknown>(); f.hold(gate.promise);
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => { button("Load project model").click(); await f.entered.promise; });
    const operationID = f.controller.snapshot().operationID!;
    expect(button("Load project model").disabled).toBe(true);
    await act(async () => button("Stop this operation").click());
    expect(f.domain.operation(operationID)?.phase).toBe("cancelled");
    expect(button("Load project model").disabled).toBe(false);
    await act(async () => { f.sent[0]!.onProgress?.({ output: "late progress" }); gate.resolve({}); });
    expect(container.textContent).not.toContain("late progress");
    expect(container.querySelector('[role="alert"]')).toBeNull();
  } finally { gate.resolve({}); await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("a newer task replaces the operation slot without late completion replacing its output", async () => {
  const f = fixture(), gate = deferred<unknown>();
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    f.hold(gate.promise);
    await act(async () => button("Upstream compile").click());
    const oldID = f.controller.snapshot().operationID!;
    await act(async () => button("Upstream compile").click());
    const newID = f.controller.snapshot().operationID!;
    expect(newID).not.toBe(oldID);
    expect(f.domain.operation(oldID)?.phase).toBe("cancelled");
    await act(async () => {
      f.sent[1]!.onProgress?.({ output: "old task progress" });
      gate.resolve({ exitCode: 0, output: "new task output" });
    });
    expect(f.domain.operation(newID)?.phase).toBe("succeeded");
    expect(container.textContent).toContain("new task output");
    expect(container.textContent).not.toContain("old task progress");
  } finally { gate.resolve({ exitCode: 0, output: "released" }); await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("failed detection and incomplete models keep visible errors without presenting executable tasks", async () => {
  const f = fixture();
  try {
    f.model({ ...model, truncated: true });
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    expect(button("Upstream compile").disabled).toBe(true);
    expect(container.querySelector('[role="alert"]')?.textContent).toContain("complete current Build model");
    f.failDetection(); await act(async () => { await f.controller.refresh(); });
    expect(container.textContent).toContain("Detection rejected");
    expect(button("Upstream compile")).toBeUndefined();
    expect(f.sent).toHaveLength(1);
  } finally { await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("a model invalidated outside the task window disappears before another task can be clicked", async () => {
  const f = fixture();
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    expect(button("Upstream compile")).toBeDefined();
    await act(async () => f.domain.invalidate(f.controller.snapshot().entries[0]!));
    expect(button("Upstream compile")).toBeUndefined();
    expect(f.sent).toHaveLength(1);
  } finally { await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("declared task scope follows the selected module and argument confirmation preserves exact argv", async () => {
  const f = fixture();
  f.manifest({ id: "dev.example.build", buildSystems: [{ id: "example", tasks: [
    { id: "compile", displayName: "Declared compile", source: "provider", scopes: ["workspace", "project"], group: "build" },
    { id: "goal", displayName: "Custom goal", source: "provider", scopes: ["workspace", "project"], requiresUserArguments: true, group: "other" },
  ] }] });
  // Exercise the product handlers independently of Base UI's cached native
  // portal/input feature detection when several suites share one Bun process.
  const dialog = spyOn(dialogControl, "default").mockImplementation((({ children, title, footer }) =>
    <div role="dialog">{title}{children}{footer}</div>) as typeof dialogControl.default);
  const input = spyOn(inputControl, "default").mockImplementation((({ value, disabled, onChange, "aria-label": label }) =>
    <input value={value} disabled={disabled} aria-label={label} onInput={event => onChange?.({ ...event, target: event.currentTarget })} />) as typeof inputControl.default);
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    await act(async () => button("Declared compile").click());
    expect(f.sent[1]!.params).toMatchObject({ task: "compile", project: { id: "app", path: "app" } });
    await act(async () => {
      const select = container.querySelector<HTMLSelectElement>('select[aria-label="Project or module"]')!;
      select.value = ""; select.dispatchEvent(new Event("change", { bubbles: true }));
    });
    expect(button("Upstream compile")).toBeUndefined();
    await act(async () => button("Custom goal").click());
    expect(f.sent).toHaveLength(2);
    await act(async () => button("Cancel").click());
    expect(f.sent).toHaveLength(2);
    await act(async () => button("Custom goal").click());
    for (let index = 0; index < 3; index++) await act(async () => button("Add argument").click());
    const expected = ["verify", "-Dtitle=a b", "", "C:\\cache\\local"];
    await act(async () => {
      for (const [index, text] of expected.entries()) {
        const node = container.querySelector<HTMLInputElement>(`input[aria-label="Argument ${index + 1}"]`)!;
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(node, text);
        node.dispatchEvent(new Event("input", { bubbles: true }));
      }
    });
    await act(async () => button("Run task").click());
    expect(f.sent[2]!.params).toMatchObject({ task: "goal", userArguments: expected });
    expect((f.sent[2]!.params as Record<string, unknown>).project).toBeUndefined();
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  } finally { dialog.mockRestore(); input.mockRestore(); await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("dependency navigation expands canonical upstream nodes and clears with its model", async () => {
  const f = fixture();
  f.manifest({ id: "dev.example.build", buildSystems: [{ id: "example", dependencies: { source: "provider" } }] });
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    await act(async () => button("Load dependencies").click());
    expect(f.sent[1]!.params).toMatchObject({ project: { id: "app", path: "app" } });
    expect(container.textContent).toContain("Upstream library");
    expect(container.textContent).not.toContain("Nested library");
    await act(async () => container.querySelector<HTMLButtonElement>('button[aria-expanded="false"]')!.click());
    expect(container.textContent).toContain("Nested library");
    await act(async () => f.domain.invalidate(f.controller.snapshot().entries[0]!));
    expect(container.textContent).not.toContain("Upstream library");
    expect(f.sent).toHaveLength(2);
  } finally { await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("large task models mount only the virtualizer's visible rows", async () => {
  const f = fixture();
  f.model({ ...model, tasks: Array.from({ length: 10_000 }, (_, index) => ({ ...model.tasks[0]!, id: `task-${index}`, name: `Task ${index}` })) });
  // Browser layout is owned by the shared virtualizer. Fix its viewport here
  // so this regression measures mounted controls, not happy-dom geometry.
  const virtual = spyOn(virtualization, "useVirtualizer").mockImplementation((() => ({
    getTotalSize: () => 300_000,
    getVirtualItems: () => Array.from({ length: 12 }, (_, index) => ({ index, key: `task-${index}`, start: index * 30, size: 30 })),
  })) as unknown as typeof virtualization.useVirtualizer);
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    expect(button("Task 0")).toBeDefined();
    expect(button("Task 10")).toBeDefined();
    expect(button("Task 11")).toBeUndefined();
    expect(container.querySelectorAll("button").length).toBeLessThan(25);
  } finally { await act(async () => { await f.controller.dispose(); }); virtual.mockRestore(); }
}, 5000);

test("Provider test discovery runs an exact module selector and presents canonical failures and source links", async () => {
  const f = fixture(), navigations: unknown[][] = [];
  f.manifest({ id: "dev.example.build", buildSystems: [{ id: "example", tasks: [],
    test: { source: "provider", discovery: true, scopes: ["workspace", "project"] } }] });
  try {
    await f.controller.refresh(); await render(f.controller, "en-US", (...location) => { navigations.push(location); });
    await act(async () => button("Load project model").click());
    await act(async () => button("Discover tests").click());
    const runTest = [...container.querySelectorAll<HTMLButtonElement>("button")].find(value => value.title === "ExampleTest.fails" || value.textContent === "ExampleTest.failsApp")!;
    expect(runTest).toBeDefined();
    await act(async () => runTest.click());
    expect(f.sent[f.sent.length - 1]).toMatchObject({ method: "build.testPlan", params: { project: model.projects[0], suite: "ExampleTest", case: "fails" } });
    expect(container.textContent).toContain("1 tests · 0 passed · 1 failed · 0 errors · 0 skipped");
    expect(container.textContent).toContain("Expected upstream value");
    await act(async () => button("Upstream warning").click());
    expect(navigations).toEqual([["app/Main.java", 7, 2]]);
    const outcome = container.querySelector<HTMLButtonElement>('[data-status="failed"] button')!;
    await act(async () => outcome.click()); expect(navigations[navigations.length - 1]).toEqual(["app/ExampleTest.java", 9, undefined]);
    await act(async () => f.domain.invalidate(f.controller.snapshot().entries[0]!));
    expect(container.textContent).not.toContain("Expected upstream value");
  } finally { await act(async () => { await f.controller.dispose(); }); }
}, 5000);

test("large canonical reports mount only visible result rows", async () => {
  const f = fixture();
  f.manifest({ id: "dev.example.build", buildSystems: [{ id: "example", tasks: [], test: { source: "provider", scopes: ["project"] } }] });
  f.report({ success: true, summary: { total: 10_000, passed: 10_000, failed: 0, errors: 0, skipped: 0 },
    tests: Array.from({ length: 10_000 }, (_, index) => ({ suite: "LargeSuite", case: `case${index}`, status: "passed", invocations: 1 })) });
  const virtual = spyOn(virtualization, "useVirtualizer").mockImplementation(((options: { count: number }) => ({
    getTotalSize: () => options.count * 48, measureElement: () => {},
    getVirtualItems: () => Array.from({ length: Math.min(options.count, 12) }, (_, index) => ({ index, key: index, start: index * 48, size: 48 })),
  })) as unknown as typeof virtualization.useVirtualizer);
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    await act(async () => button("Run tests").click());
    expect(container.querySelectorAll('[data-status="passed"]')).toHaveLength(11);
    expect(container.textContent).toContain("10000 tests"); expect(container.textContent).not.toContain("LargeSuite.case9999");
  } finally { await act(async () => { await f.controller.dispose(); }); virtual.mockRestore(); }
}, 5000);

test("streamed output never recopies a completed structured report", async () => {
  const f = fixture(), entered = deferred<void>(), result = deferred<unknown>();
  let started: ReturnType<typeof f.domain.executeTask> | undefined;
  const read = spyOn(f.domain, "result");
  try {
    await f.controller.refresh(); await render(f.controller);
    await act(async () => button("Load project model").click());
    await act(async () => button("Upstream compile").click());
    const before = read.mock.calls.length;
    f.hold(result.promise); f.onProvider(() => entered.resolve());
    await act(async () => {
      started = f.domain.executeTask(f.controller.snapshot().entries[0]!, "compile", "app");
      await entered.promise;
      for (let index = 0; index < 100; index++) f.sent[f.sent.length - 1]?.onProgress?.({ output: `line ${index}\n` });
    });
    expect(read.mock.calls.length).toBe(before);
    result.resolve({ exitCode: 0, output: "finished" });
    await act(async () => { await started!.completion; });
  } finally {
    result.resolve({ exitCode: 0, output: "released" });
    await act(async () => { await started?.completion.catch(() => {}); await f.controller.dispose(); }); read.mockRestore();
  }
}, 5000);
