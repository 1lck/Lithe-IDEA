import { afterAll, afterEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import * as tauri from "@/platform/tauri-core";
import * as events from "@tauri-apps/api/event";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { buildSystemViewId, useBuildSystemsStore } from "../build-systems-store";
import { useBuildOutputStore } from "../output/build-output-store";
import type { BuildRunNative } from "../build-run-native";
import type { BuildRunDefinition, BuildRunReview } from "../build-run-types";
import type { BuildView } from "../build-systems-types";
import type { BuildOutputEvent, BuildRunTerminal } from "../output/build-output-types";

const restoreDom = installHappyDom();
const { useFileSystemStore } = await import("@/features/file-system/stores/file-system.store");
const { createRoot } = await import("react-dom/client");
const { default: BuildSystemPane } = await import("./build-system-pane");
afterAll(restoreDom);
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  workspaceRuntimeRegistry.resetForTests();
});
function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  cleanups.push(() => resolve(fallback));
  return { promise, resolve, reject };
}
const ROOT = "D:/fixture/run-ui";
const PLUGIN = "dev.lithe.fixture.run-ui";
const VIEW = buildSystemViewId(PLUGIN, "fixture");
function view(): BuildView {
  return {
    generation: 3,
    workspaceRoot: ROOT,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture",
        displayName: "Fixture",
        root: ".",
        markers: [],
        modelSource: "command",
        model: {
          projects: [
            { id: "project-app", name: "App", path: "app" },
            { id: "project-other", name: "Other", path: "other" },
          ],
          targets: [
            {
              id: "test-target",
              projectID: "project-app",
              name: "Integration target",
              path: "app",
              tags: ["test", "integration", "smoke"],
            },
            {
              id: "library-target",
              projectID: "project-app",
              name: "Library target",
              tags: ["library"],
            },
            {
              id: "other-target",
              projectID: "project-other",
              name: "Other project target",
              tags: ["test"],
            },
          ],
          tasks: [
            {
              id: "model-task",
              projectID: "project-app",
              name: "verifyEverything",
              displayName: "Verify everything",
              template: "from-model",
              execution: "task",
              category: ["Checks", "Extended"],
            },
            {
              id: "background",
              projectID: "project-app",
              name: "Background service",
              template: "from-model",
              execution: "service",
            },
          ],
        },
        stale: false,
        syncDigest: "sync",
        optionFingerprint: "options",
        options: [],
      },
    ],
  };
}
const definition: BuildRunDefinition = {
  tasks: [
    {
      id: "build",
      displayName: "Build fixture",
      scopes: ["workspace", "project", "target"],
      targetTags: ["test"],
      execution: "task",
      category: ["Lifecycle"],
    },
    { id: "from-model", displayName: "Model tasks", fromModel: true },
    {
      id: "application",
      displayName: "Application entry",
      execution: "application",
      scopes: ["workspace"],
    },
    { id: "service", displayName: "Service entry", execution: "service", scopes: ["workspace"] },
  ],
  test: {
    scopes: ["workspace", "project", "target"],
    targetTags: ["test"],
    filters: ["suite", "case"],
  },
  programs: [
    {
      kind: "buildSystem",
      buildSystemID: "fixture",
      invocation: {
        executables: [
          { kind: "projectFile", path: "fixture-wrapper.cmd" },
          { kind: "command", command: "fixture-tool" },
        ],
      },
      tasks: [{ id: "build", arguments: ["build", "${userArguments}"] }],
    },
  ],
};
let nextId = 0;
function press(element: HTMLElement) {
  element.dispatchEvent(
    new window.PointerEvent("pointerdown", { bubbles: true, pointerType: "mouse", button: 0 }),
  );
  element.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  element.dispatchEvent(new window.MouseEvent("mouseup", { bubbles: true, button: 0 }));
  element.dispatchEvent(new window.MouseEvent("click", { bubbles: true, button: 0, detail: 1 }));
}
function openSelect(element: HTMLElement) {
  element.dispatchEvent(new window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
}
async function mount(initial = view(), language: "en-US" | "zh-CN" = "en-US") {
  const workspaceId = `run-ui-${++nextId}`;
  workspaceRuntimeRegistry.activateWorkspace(
    { id: workspaceId, name: "Fixture", path: ROOT },
    "ready",
  );
  const store = useBuildSystemsStore.getStore(workspaceId);
  store.getState().actions.applyView(initial, store.getState().actions.beginRequest());
  useBuildOutputStore.getStore(workspaceId);
  const review: BuildRunReview = {
    operationId: `native-${nextId}`,
    pluginId: PLUGIN,
    buildSystemId: "fixture",
    workspaceRoot: ROOT,
    root: ".",
    generation: 3,
    executesProjectCode: true,
    mayUseNetwork: true,
    kind: "task",
    title: "Build fixture",
  };
  const completion = deferred<BuildRunTerminal>({ kind: "cancelled" });
  const sinks: Array<(event: BuildOutputEvent) => void> = [];
  const unlisten = mock(() => {});
  const native: BuildRunNative = {
    windowLabel: () => "workspace-run-ui",
    definition: mock(async () => definition),
    save: mock(async () => {}),
    sync: mock(async () => {
      const actions = store.getState().actions;
      actions.applyView(initial, actions.beginRequest());
    }),
    prepare: mock(async (_workspace, _plugin, _system, _root, selection) => ({
      ...review,
      kind: selection.kind,
    })),
    execute: mock(async () => {
      const result = await completion.promise;
      sinks[sinks.length - 1]?.({ ...review, type: "terminal", terminal: result });
      return result;
    }),
    cancel: mock(async () => {}),
    listen: mock(async (_window, sink) => {
      sinks.push(sink);
      return unlisten;
    }),
  };
  const invoke = spyOn(tauri, "invoke").mockImplementation(
    async <T,>(command: string): Promise<T> => {
      if (command === "declarative_plugins_build_catalog") return [] as T;
      if (command === "declarative_plugins_build_refresh") return initial as T;
      throw new Error(`unexpected native command ${command}`);
    },
  );
  const listen = spyOn(events, "listen").mockResolvedValue(() => {});
  cleanups.push(() => {
    invoke.mockRestore();
    listen.mockRestore();
  });
  const env = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previous = env.IS_REACT_ACT_ENVIRONMENT;
  env.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  cleanups.push(async () => {
    await act(async () => root.unmount());
    host.remove();
    if (previous === undefined) delete env.IS_REACT_ACT_ENVIRONMENT;
    else env.IS_REACT_ACT_ENVIRONMENT = previous;
  });
  const render = () =>
    root.render(
      <LocaleProvider language={language}>
        <BuildSystemPane view={VIEW} onClose={() => {}} runNative={native} />
      </LocaleProvider>,
    );
  await act(async () => render());
  const button = (text: string) =>
    [...document.querySelectorAll<HTMLButtonElement>("button")].find(
      (row) => row.textContent === text,
    )!;
  const choose = async (label: string, option: string) => {
    await act(async () =>
      openSelect(host.querySelector<HTMLButtonElement>(`[aria-label="${label}"]`)!),
    );
    const row = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find(
      (value) => value.textContent === option,
    )!;
    expect(row).toBeDefined();
    await act(async () => press(row));
  };
  const input = async (label: string, value: string) => {
    const element = host.querySelector<HTMLInputElement | HTMLTextAreaElement>(
      `[aria-label="${label}"]`,
    )!;
    const prototype =
      element.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    await act(async () => {
      Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(element, value);
      element.dispatchEvent(
        new window.InputEvent("input", { bubbles: true, inputType: "insertText" }),
      );
    });
  };
  const prepare = async () => {
    await act(async () =>
      button(language === "en-US" ? "Prepare task / test…" : "准备任务 / 测试…").click(),
    );
  };
  const send = async (event: Partial<BuildOutputEvent>) => {
    await act(async () => sinks[sinks.length - 1]!({ ...review, ...event } as BuildOutputEvent));
  };
  return {
    host,
    root,
    render,
    native,
    review,
    completion,
    store,
    workspaceId,
    button,
    choose,
    input,
    prepare,
    send,
    unlisten,
  };
}

test("production tool window displays flat model IDs and complete tags; passive selection never executes", async () => {
  const f = await mount();
  expect(f.host.textContent).toContain("Integration target");
  expect(f.host.textContent).toContain("[test, integration, smoke]");
  expect(f.native.save).toHaveBeenCalledTimes(0);
  expect(f.native.prepare).toHaveBeenCalledTimes(0);
  await f.choose("Action", "Lifecycle / Build fixture");
  await f.choose("Scope", "Target");
  await f.choose("Project", "App (app)");
  await act(async () =>
    openSelect(f.host.querySelector<HTMLButtonElement>('[aria-label="Target"]')!),
  );
  const choices = [...document.querySelectorAll<HTMLElement>('[role="option"]')].map(
    (row) => row.textContent,
  );
  expect(choices).toContain("Integration target [test, integration, smoke]");
  expect(choices).not.toContain("Library target [library]");
  expect(choices).not.toContain("Other project target [test]");
  await act(async () =>
    press(
      [...document.querySelectorAll<HTMLElement>('[role="option"]')].find(
        (row) => row.textContent === "Integration target [test, integration, smoke]",
      )!,
    ),
  );
  expect(f.native.prepare).toHaveBeenCalledTimes(0);
  expect(f.native.execute).toHaveBeenCalledTimes(0);
});
test("task preparation uses selected native IDs, literal arguments and full program approval before live output", async () => {
  const f = await mount();
  await f.choose("Action", "Lifecycle / Build fixture");
  await f.choose("Scope", "Target");
  await f.choose("Project", "App (app)");
  await f.choose("Target", "Integration target [test, integration, smoke]");
  await f.input("Arguments (one literal argument per line)", "--fixture\nvalue with spaces");
  await f.prepare();
  expect(f.native.prepare).toHaveBeenCalledWith(ROOT, PLUGIN, "fixture", ".", {
    kind: "task",
    taskId: "build",
    projectId: "project-app",
    targetId: "test-target",
    modelTaskId: null,
    suite: null,
    case: null,
    userArguments: ["--fixture", "value with spaces"],
  });
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  const dialog = document.querySelector('[role="dialog"]')!;
  for (const text of [
    PLUGIN,
    ROOT,
    f.review.operationId,
    "fixture-wrapper.cmd",
    "${userArguments}",
    "may execute code",
    "may access the network",
  ])
    expect(dialog.textContent).toContain(text);
  await act(async () => f.button("Allow and execute").click());
  expect(f.native.execute).toHaveBeenCalledTimes(1);
  expect(f.native.listen).toHaveBeenCalledTimes(1);
  await f.send({ type: "chunk", stream: "stderr", text: "native build warning\n" });
  await act(async () =>
    f.completion.resolve({ kind: "failed", exitCode: 1, message: "fixture compiler failed" }),
  );
  expect(f.host.textContent).toContain("native build warning");
  expect(f.host.textContent).toContain("fixture compiler failed");
});
test("test suite/case selection delivers decoded failures and jumps through the existing source opener", async () => {
  const f = await mount();
  await f.choose("Action", "Tests");
  await f.choose("Scope", "Target");
  await f.choose("Project", "App (app)");
  await f.choose("Target", "Integration target [test, integration, smoke]");
  await f.input("Test suite filter", "fixture.Suite");
  await f.input("Test case filter", "failsCase");
  await f.prepare();
  expect(f.native.prepare).toHaveBeenCalledWith(
    ROOT,
    PLUGIN,
    "fixture",
    ".",
    expect.objectContaining({
      kind: "test",
      taskId: null,
      suite: "fixture.Suite",
      case: "failsCase",
      targetId: "test-target",
    }),
  );
  await act(async () => f.button("Allow and execute").click());
  const files = useFileSystemStore.getStore(f.workspaceId);
  const original = files.getState().handleFileSelect;
  const opened: unknown[][] = [];
  files.setState({
    handleFileSelect: async (...args) => {
      opened.push(args);
      return undefined;
    },
  });
  cleanups.push(() => files.setState({ handleFileSelect: original }));
  await f.send({
    type: "diagnostics",
    diagnostics: [
      {
        path: "app/main.ts",
        line: 4,
        column: 9,
        severity: "error",
        message: "native fixture diagnostic",
      },
    ],
  });
  await f.send({
    type: "testResults",
    results: {
      tests: [
        {
          suite: "fixture.Suite",
          case: "failsCase",
          status: "failed",
          message: "expected fixture value",
          path: "app/test.ts",
          line: 5,
          invocations: 1,
        },
      ],
      summary: { total: 1, passed: 0, failed: 1, errors: 0, skipped: 0 },
      success: false,
    },
  });
  expect(f.host.textContent).toContain("native fixture diagnostic");
  expect(f.host.textContent).toContain("expected fixture value");
  await act(async () =>
    f.host.querySelector<HTMLButtonElement>('[data-slot="build-output-problems"] button')!.click(),
  );
  expect(opened).toEqual([
    [expect.stringMatching(/D:[\\/]fixture[\\/]run-ui[\\/]app[\\/]main\.ts/), false, 4, 9],
  ]);
  await act(async () => f.completion.resolve({ kind: "failed", exitCode: 1 }));
});
test("only task execution model entries are selectable and rejection never executes", async () => {
  const f = await mount();
  await f.choose("Action", "Model tasks");
  await f.choose("Project", "App (app)");
  await act(async () =>
    openSelect(f.host.querySelector<HTMLButtonElement>('[aria-label="Model task"]')!),
  );
  expect(document.body.textContent).toContain("Checks / Extended / Verify everything");
  expect(document.querySelector('[role="listbox"]')!.textContent).not.toContain(
    "Background service",
  );
  const model = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find(
    (row) => row.textContent === "Checks / Extended / Verify everything",
  )!;
  await act(async () => press(model));
  await f.prepare();
  expect(f.native.prepare).toHaveBeenCalledWith(
    ROOT,
    PLUGIN,
    "fixture",
    ".",
    expect.objectContaining({
      modelTaskId: "model-task",
      taskId: "from-model",
      projectId: "project-app",
    }),
  );
  await act(async () => f.button("Decline").click());
  expect(f.native.execute).toHaveBeenCalledTimes(0);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
});
test("modelReloadRequired gives a localized recovery action rather than entering execute", async () => {
  const f = await mount(view(), "zh-CN");
  f.native.prepare = mock(async () => {
    throw new Error("plugin.build.modelReloadRequired");
  });
  await f.choose("操作", "测试");
  await f.prepare();
  expect(f.host.textContent).toContain("模型缺失或已过期");
  expect(f.host.textContent).toContain("加载 / 重新加载模型");
  expect(f.native.execute).toHaveBeenCalledTimes(0);
});
test("closing and reopening the production window retains failed cancellation and retries the original operation", async () => {
  const f = await mount();
  await f.choose("Action", "Lifecycle / Build fixture");
  await f.prepare();
  await act(async () => f.button("Allow and execute").click());
  f.native.cancel = mock(async () => {
    throw new Error("fixture failed cleanup");
  });
  await act(async () => f.root.render(null));
  expect(f.unlisten).toHaveBeenCalledTimes(1);
  await act(async () => f.render());
  expect(f.host.textContent).toContain("fixture failed cleanup");
  expect(f.button("Retry cancellation")).toBeDefined();
  f.native.cancel = mock(async () => {});
  await act(async () => f.button("Retry cancellation").click());
  expect(f.native.cancel).toHaveBeenCalledWith(f.review.operationId);
  await act(async () => f.completion.resolve({ kind: "cancelled" }));
  expect(f.host.textContent).toContain("Task / test operation ended");
});
