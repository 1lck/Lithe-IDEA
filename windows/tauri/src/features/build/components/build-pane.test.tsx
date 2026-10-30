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
  let pending: Promise<unknown> | undefined, decodedModel = structuredClone(model), failedDetection = false;
  const core = (async (command: string, _manifest: unknown, _system: string, request: Record<string, unknown>) => {
    if (command.endsWith("Plan")) return { plan: { provider: { method: command, params: request } } };
    if (command === "build.decodeModel") return { model: decodedModel };
    if (command === "build.decodeDiagnostics") return { diagnostics: [] };
    throw new Error(`Unexpected command ${command}`);
  }) as typeof buildCore;
  const domain = new WindowsBuildProviderWorkspace("C:/work", { core, translate: createTranslator("en-US"), guard: () => () => {},
    tools: async () => ({ manifest: { id: "dev.example.build" }, pluginDirectory: "C:/plugin", workspaceStateDirectory: "C:/state",
      tool: { executable: "C:/tool" }, environment: {}, executesProjectCode: false }),
    providers: { send: async <T,>(_target: unknown, request: Request) => {
      sent.push(request); entered.resolve();
      return (pending ? await pending : { exitCode: 0, output: "upstream output\n" }) as T;
    }, stop: async () => {} },
  });
  const controller = new BuildWorkspaceController("C:/work", { domain, guard: () => () => {}, detect: async () => {
    if (failedDetection) throw new Error("Detection rejected");
    return structuredClone(catalog);
  } });
  return { domain, controller, sent, entered, hold: (gate?: Promise<unknown>) => { pending = gate; },
    model: (value: BuildModel) => { decodedModel = value; }, failDetection: () => { failedDetection = true; } };
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
function Surface({ controller, language }: { controller: BuildWorkspaceController; language: "en-US" | "zh-CN" }) {
  const snapshot = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  return <LocaleProvider language={language}><BuildPaneContent controller={controller} snapshot={snapshot} />
    <BuildOutputContent domain={controller.domain} operationID={snapshot.operationID} /></LocaleProvider>;
}
async function render(controller: BuildWorkspaceController, language: "en-US" | "zh-CN" = "en-US") {
  await act(async () => { root.render(<Surface controller={controller} language={language} />); });
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
    expect(button("Task 11")).toBeDefined();
    expect(button("Task 12")).toBeUndefined();
    expect(container.querySelectorAll("button").length).toBeLessThan(25);
  } finally { virtual.mockRestore(); await act(async () => { await f.controller.dispose(); }); }
}, 5000);
