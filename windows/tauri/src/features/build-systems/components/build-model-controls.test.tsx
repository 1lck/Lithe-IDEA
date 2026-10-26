import { afterAll, afterEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
import * as events from "@tauri-apps/api/event";
import * as native from "@/platform/tauri-core";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { buildSystemViewId, useBuildSystemsStore } from "../build-systems-store";
import { BuildModelCancellationError } from "../build-systems-service";
import type { BuildModelLoadResult, BuildModelReview, BuildView } from "../build-systems-types";
import type { BuildModelService } from "./build-model-controls";
import type { BuildRunNative } from "../build-run-native";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildSystemPane } = await import("./build-system-pane");
afterAll(restoreDom);
const cleanups: Array<() => void | Promise<void>> = [];
const noRun = async (): Promise<never> => {
  throw new Error("unexpected task/test execution in model-only test");
};
const passiveRunNative: BuildRunNative = {
  windowLabel: () => "workspace-model-tests",
  definition: async () => ({ tasks: [], programs: [] }),
  save: noRun,
  sync: noRun,
  prepare: noRun,
  execute: noRun,
  cancel: noRun,
  listen: noRun,
};
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  workspaceRuntimeRegistry.resetForTests();
});
function deferred<T>(cleanupValue: T) {
  let resolve!: (value: T) => void;
  let reject!: (failure: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  cleanups.push(() => resolve(cleanupValue));
  return { promise, resolve, reject };
}
const PLUGIN = "dev.lithe.fixture.model-command";
const ROOT = "C:/fixture/model-ui-workspace";
const VIEW = buildSystemViewId(PLUGIN, "fixture-build");
const review: BuildModelReview = {
  pluginId: PLUGIN,
  buildSystemId: "fixture-build",
  operationId: "review-operation-1",
  workspaceRoot: ROOT,
  root: ".",
  generation: 3,
  executesProjectCode: true,
  mayUseNetwork: true,
};
function view(): BuildView {
  return {
    generation: 3,
    workspaceRoot: ROOT,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "fixture-build",
        displayName: "Fixture",
        root: ".",
        markers: [],
        modelSource: "command",
        model: null,
        stale: false,
        syncDigest: null,
        optionFingerprint: "options",
        options: [],
      },
    ],
  };
}
function apply(next: BuildView) {
  const actions = useBuildSystemsStore.getState().actions;
  actions.applyView(next, actions.beginRequest());
}
function fakeService() {
  const prepared = deferred<BuildModelReview>(review);
  const result = deferred<BuildModelLoadResult | null>(null);
  const declinedCleanup = deferred<void>(undefined);
  const controller = new AbortController();
  cleanups.push(() => controller.abort());
  let callerSignal: AbortSignal | undefined;
  let executes = 0;
  const service: BuildModelService = {
    load: mock(async (_plugin, _system, _root, approve, _runtimes, options) => {
      callerSignal = options?.signal;
      const abort = () => controller.abort();
      callerSignal?.addEventListener("abort", abort, { once: true });
      try {
        const nextReview = await prepared.promise;
        options?.onPrepared?.(nextReview);
        if (callerSignal?.aborted) return null;
        const accepted = await approve(nextReview, controller.signal);
        if (!accepted || callerSignal?.aborted || controller.signal.aborted) {
          await declinedCleanup.promise;
          return null;
        }
        executes += 1;
        return await result.promise;
      } finally {
        callerSignal?.removeEventListener("abort", abort);
      }
    }),
    cancel: mock(async () => {
      controller.abort();
    }),
  };
  return {
    service,
    prepared,
    result,
    declinedCleanup,
    controller,
    get signal() {
      return callerSignal;
    },
    get executes() {
      return executes;
    },
  };
}
async function mount(
  initial = view(),
  fake = fakeService(),
  language: "en-US" | "zh-CN" = "en-US",
) {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "model-ui-tests", name: "Fixture", path: ROOT },
    "ready",
  );
  useBuildSystemsStore.getState().actions.reset();
  apply(initial);
  // Workspace activation normally prepares stores before rendering consumers.
  useBuildSystemsStore.getStore("other-model-workspace");
  const invoke = spyOn(native, "invoke").mockImplementation(async <T,>(command: string) => {
    if (command === "declarative_plugins_build_catalog") return [] as T;
    if (command === "declarative_plugins_build_refresh") return initial as T;
    throw new Error(`unexpected native call ${command}`);
  });
  const listen = spyOn(events, "listen").mockResolvedValue(() => {});
  cleanups.push(() => {
    invoke.mockRestore();
    listen.mockRestore();
  });
  const env = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = env.IS_REACT_ACT_ENVIRONMENT;
  env.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  cleanups.push(async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete env.IS_REACT_ACT_ENVIRONMENT;
      else env.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  });
  await act(async () =>
    root.render(
      <LocaleProvider language={language}>
        <BuildSystemPane
          view={VIEW}
          onClose={() => {}}
          modelService={fake.service}
          runNative={passiveRunNative}
        />
      </LocaleProvider>,
    ),
  );
  const button = (text: string) =>
    [...document.querySelectorAll<HTMLButtonElement>("button")].find(
      (row) => row.textContent === text,
    )!;
  const start = async () => {
    await act(async () =>
      button(
        language === "en-US"
          ? initial.instances[0]!.model
            ? "Reload model…"
            : "Load model…"
          : "加载模型…",
      ).click(),
    );
  };
  const prepare = async (value = review) => {
    await act(async () => fake.prepared.resolve(value));
  };
  return { host, root, fake, button, start, prepare, invoke };
}

test("opening, detecting and changing instance remain passive; only an explicit load prepares a review", async () => {
  const initial = view();
  initial.instances.push({ ...initial.instances[0]!, root: "nested" });
  const { fake, host, start, prepare, button } = await mount(initial);
  expect(fake.service.load).toHaveBeenCalledTimes(0);
  await act(async () => useBuildSystemsStore.getState().actions.selectInstance(VIEW, "nested"));
  expect(fake.service.load).toHaveBeenCalledTimes(0);
  await act(async () => useBuildSystemsStore.getState().actions.selectInstance(VIEW, "."));
  await start();
  expect(fake.service.load).toHaveBeenCalledTimes(1);
  expect(fake.executes).toBe(0);
  expect(host.textContent).toContain("Preparing model review");
  await prepare();
  const dialog = document.querySelector('[role="dialog"]')!;
  expect(dialog).not.toBeNull();
  for (const value of [PLUGIN, "fixture-build", ROOT, "review-operation-1"])
    expect(dialog.textContent).toContain(value);
  expect(dialog.textContent).toContain("may execute code");
  expect(dialog.textContent).toContain("may access the network");
  await act(async () => button("Allow and load").click());
  expect(fake.executes).toBe(1);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  expect(host.textContent).toContain("Loading model…");
  await act(async () =>
    fake.result.resolve({
      operationId: review.operationId,
      view: initial,
      stderr: "upstream fixture warning",
    }),
  );
  expect(host.textContent).toContain("Model loaded");
  expect(host.textContent).toContain("upstream fixture warning");
});

test("declining closes consent and waits for native review cleanup without execution", async () => {
  const { fake, host, start, prepare, button } = await mount();
  await start();
  await prepare();
  await act(async () => button("Decline").click());
  expect(fake.executes).toBe(0);
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  expect(host.textContent).toContain("waiting for operation cleanup");
  await act(async () => fake.declinedCleanup.resolve());
  expect(host.textContent).toContain("Model loading declined");
});

test("duplicate clicks prepare only once and approval can execute only once", async () => {
  const { fake, prepare, button } = await mount();
  await act(async () => {
    button("Load model…").click();
    button("Load model…").click();
  });
  expect(fake.service.load).toHaveBeenCalledTimes(1);
  await prepare();
  const approve = button("Allow and load");
  await act(async () => {
    approve.click();
    approve.click();
  });
  expect(fake.executes).toBe(1);
  await act(async () => fake.result.resolve(null));
});

test("cancellation failure remains actionable and retry awaits confirmation; late success is discarded", async () => {
  const { fake, host, start, prepare, button } = await mount();
  const cancellation = deferred<void>(undefined);
  fake.service.cancel = mock(() => cancellation.promise);
  await start();
  await prepare();
  await act(async () => button("Allow and load").click());
  await act(async () => button("Cancel model loading").click());
  expect(host.textContent).toContain("waiting for operation cleanup");
  expect(host.textContent).not.toContain("Model loaded");
  await act(async () => cancellation.reject(new Error("fixture cleanup failed")));
  expect(host.querySelector('[role="alert"]')!.textContent).toContain("fixture cleanup failed");
  expect(button("Load model…").disabled).toBe(true);
  const retry = deferred<void>(undefined);
  fake.service.cancel = mock(() => retry.promise);
  await act(async () => button("Retry cancellation").click());
  expect(host.textContent).toContain("waiting for operation cleanup");
  await act(async () => retry.resolve());
  expect(fake.service.cancel).toHaveBeenCalledWith(review.operationId);
  expect(fake.signal!.aborted).toBe(true);
  await act(async () =>
    fake.result.resolve({ operationId: review.operationId, view: view(), stderr: "late stderr" }),
  );
  expect(host.textContent).not.toContain("Model loaded");
  expect(host.textContent).not.toContain("late stderr");
  expect(button("Load model…").disabled).toBe(false);
});

test("cancelling during preparation aborts the caller and a late prepare never opens consent", async () => {
  const { fake, host, start, prepare, button } = await mount();
  await start();
  await act(async () => button("Cancel model loading").click());
  expect(fake.signal!.aborted).toBe(true);
  expect(host.textContent).toContain("waiting for operation cleanup");
  await prepare();
  expect(document.querySelector('[role="dialog"]')).toBeNull();
  expect(fake.executes).toBe(0);
});

for (const change of ["instance", "workspace", "generation", "disable", "unmount"] as const) {
  test(`consent is closed and cannot execute after ${change} invalidates its owner`, async () => {
    const initial = view();
    initial.instances.push({ ...initial.instances[0]!, root: "nested" });
    const { fake, root, start, prepare, button } = await mount(initial);
    await start();
    await prepare();
    const staleApprove = button("Allow and load");
    await act(async () => {
      if (change === "instance")
        useBuildSystemsStore.getState().actions.selectInstance(VIEW, "nested");
      else if (change === "workspace")
        workspaceRuntimeRegistry.activateWorkspace(
          { id: "other-model-workspace", name: "Other", path: "C:/fixture/other-model" },
          "ready",
        );
      else if (change === "generation") apply({ ...initial, generation: 4 });
      else if (change === "disable") useBuildSystemsStore.getState().actions.dropPlugin(PLUGIN);
      else root.render(null);
    });
    expect(fake.signal!.aborted).toBe(true);
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    await act(async () => staleApprove.click());
    await act(async () => fake.declinedCleanup.resolve());
    expect(fake.executes).toBe(0);
  });
}

test("prepare exceptions show a retryable failure and do not enter load", async () => {
  const { fake, host, start, button } = await mount();
  await start();
  await act(async () => fake.prepared.reject(new Error("fixture prepare failure")));
  expect(host.querySelector('[role="alert"]')!.textContent).toContain("fixture prepare failure");
  expect(host.textContent).toContain("Check the tool or project configuration");
  expect(fake.executes).toBe(0);
  expect(button("Load model…").disabled).toBe(false);
});

test("load errors and cleanup errors cannot display successful loading", async () => {
  const { fake, host, start, prepare, button } = await mount();
  await start();
  await prepare();
  await act(async () => button("Allow and load").click());
  await act(async () =>
    fake.result.reject(new BuildModelCancellationError("fixture native cleanup failed")),
  );
  expect(host.querySelector('[role="alert"]')!.textContent).toContain(
    "fixture native cleanup failed",
  );
  expect(button("Retry cancellation")).toBeDefined();
  expect(host.textContent).not.toContain("Model loaded");
});

test("a failed load enables a fresh review while keeping existing model data", async () => {
  const initial = view();
  initial.instances[0]!.model = { projects: [{ name: "Existing model", path: "." }] };
  const { fake, host, start, prepare, button } = await mount(initial);
  await start();
  await prepare();
  await act(async () => button("Allow and load").click());
  await act(async () => fake.result.reject(new Error("fixture model command failed")));
  expect(host.querySelector('[role="alert"]')!.textContent).toContain(
    "fixture model command failed",
  );
  expect(host.textContent).toContain("Existing model");
  expect(button("Reload model…").disabled).toBe(false);
});

test("a cancellation failure after late preparation retains the operation ID for Stop retry", async () => {
  const fake = fakeService();
  fake.service.load = mock(async (_plugin, _system, _root, _approve, _runtime, options) => {
    await fake.prepared.promise;
    options?.onPrepared?.(review);
    throw new BuildModelCancellationError("late prepare cleanup failed");
  });
  const { host, start, prepare, button } = await mount(view(), fake);
  await start();
  await act(async () => button("Cancel model loading").click());
  await prepare();
  expect(host.querySelector('[role="alert"]')!.textContent).toContain(
    "late prepare cleanup failed",
  );
  await act(async () => button("Retry cancellation").click());
  expect(fake.service.cancel).toHaveBeenCalledWith(review.operationId);
  expect(host.textContent).not.toContain("Model loaded");
});

test("an old cancellation callback after switching instances cannot change the new instance UI", async () => {
  const initial = view();
  initial.instances.push({ ...initial.instances[0]!, root: "nested" });
  const { fake, host, start, prepare, button } = await mount(initial);
  const cancelled = deferred<void>(undefined);
  fake.service.cancel = mock(() => cancelled.promise);
  await start();
  await prepare();
  await act(async () => button("Allow and load").click());
  await act(async () => button("Cancel model loading").click());
  await act(async () => useBuildSystemsStore.getState().actions.selectInstance(VIEW, "nested"));
  await act(async () => cancelled.reject(new Error("old stop error")));
  await act(async () =>
    fake.result.resolve({ operationId: review.operationId, view: initial, stderr: "old stderr" }),
  );
  expect(host.textContent).not.toContain("old stop error");
  expect(host.textContent).not.toContain("old stderr");
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(button("Load model…").disabled).toBe(false);
});

test("static models retain their projects without a command load entry", async () => {
  const initial = view();
  initial.instances[0]!.modelSource = "static";
  initial.instances[0]!.model = { projects: [{ name: "Static app", path: "." }] };
  const { fake, host } = await mount(initial);
  expect(host.textContent).toContain("Static app");
  expect(host.textContent).not.toContain("Load model…");
  expect(fake.service.load).toHaveBeenCalledTimes(0);
});

test("Chinese consent displays the exact review and its declared risk flags", async () => {
  const { start, prepare, button } = await mount(view(), fakeService(), "zh-CN");
  await start();
  await prepare({ ...review, executesProjectCode: false, mayUseNetwork: false });
  const dialog = document.querySelector('[role="dialog"]')!;
  expect(dialog.textContent).toContain("确认加载构建模型");
  expect(dialog.textContent).toContain("准备好的计划未声明执行项目代码");
  expect(dialog.textContent).toContain("准备好的计划未声明访问网络");
  expect(button("同意并加载")).toBeDefined();
});
