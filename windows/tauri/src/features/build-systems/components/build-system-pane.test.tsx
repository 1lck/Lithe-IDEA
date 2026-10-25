import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import * as events from "@tauri-apps/api/event";
import * as native from "@/platform/tauri-core";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { buildSystemViewId, useBuildSystemsStore } from "../build-systems-store";
import type { BuildOptionDescription, BuildView } from "../build-systems-types";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildSystemPane } = await import("./build-system-pane");
afterAll(restoreDom);

const PLUGIN = "dev.lithe.fixture.build-static-file";
const WORKSPACE = "C:/work/build-pane-fixture";
const VIEW_ID = buildSystemViewId(PLUGIN, "cargo");
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function view(options: BuildOptionDescription[] = []): BuildView {
  return {
    generation: 1,
    workspaceRoot: WORKSPACE,
    issues: [],
    instances: [
      {
        pluginID: PLUGIN,
        buildSystemID: "cargo",
        displayName: "Cargo",
        root: ".",
        markers: ["Cargo.toml"],
        modelSource: "static",
        model: { projects: [{ name: "fixture-app", path: "." }] },
        stale: false,
        syncDigest: "baseline",
        optionFingerprint: "options",
        options,
      },
    ],
  };
}

function applyView(next: BuildView): void {
  const actions = useBuildSystemsStore.getState().actions;
  actions.applyView(next, actions.beginRequest());
}

async function mount(initial = view()) {
  workspaceRuntimeRegistry.activateWorkspace(
    { id: "build-pane-tests", name: "Fixture", path: WORKSPACE },
    "ready",
  );
  useBuildSystemsStore.getState().actions.reset();
  applyView(initial);
  const invokeSpy = spyOn(native, "invoke").mockImplementation(
    async <T,>(command: string): Promise<T> => {
      if (command === "declarative_plugins_build_catalog") return [] as T;
      if (command === "declarative_plugins_build_refresh") return view() as T;
      if (command === "declarative_plugins_build_set_option") return initial as T;
      throw new Error(`unexpected command ${command}`);
    },
  );
  const listenSpy = spyOn(events, "listen").mockResolvedValue(() => {});
  cleanups.push(() => {
    invokeSpy.mockRestore();
    listenSpy.mockRestore();
  });
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root: Root = createRoot(host);
  cleanups.push(async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  });
  const render = () =>
    root.render(
      <LocaleProvider language="en-US">
        <BuildSystemPane view={VIEW_ID} onClose={() => {}} />
      </LocaleProvider>,
    );
  await act(async () => render());
  const reload = () =>
    [...host.querySelectorAll("button")].find((button) => button.textContent === "Reload")!;
  return { host, root, render, reload, invokeSpy };
}

function setInput(input: HTMLInputElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}

test("zero detected instances show an empty state with a working reload", async () => {
  const { host, reload, invokeSpy } = await mount({ ...view(), instances: [] });
  expect(host.textContent).toContain("No cargo project detected in this workspace.");

  await act(async () => reload().click());

  expect(host.textContent).toContain("fixture-app");
  expect(host.textContent).not.toContain("No cargo project detected");
  expect(
    invokeSpy.mock.calls.filter(([command]) => command === "declarative_plugins_build_refresh"),
  ).toHaveLength(1);
});

test("detection failure can be retried from the open pane", async () => {
  const { host, reload } = await mount();
  await act(async () => {
    const actions = useBuildSystemsStore.getState().actions;
    actions.fail("fixture detection failure", actions.beginRequest());
  });
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("fixture detection failure");

  await act(async () => reload().click());

  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(useBuildSystemsStore.getState().status).toBe("ready");
});

test("stale models keep a reload entry and become current after reloading", async () => {
  const { host, reload } = await mount();
  await act(async () => {
    const stale = view();
    stale.instances[0]!.stale = true;
    applyView(stale);
  });
  expect(host.textContent).toContain("The project model is out of date.");

  await act(async () => reload().click());

  expect(host.textContent).not.toContain("The project model is out of date.");
  expect(useBuildSystemsStore.getState().windows[VIEW_ID]?.instances[0]?.stale).toBe(false);
});

for (const outcome of ["failed", "stale"] as const) {
  test(`reopening a ${outcome} pane retries once without a render loop`, async () => {
    const { root, render, invokeSpy } = await mount();
    await act(async () => root.render(null));
    const actions = useBuildSystemsStore.getState().actions;
    if (outcome === "failed") {
      actions.fail("retry on reopen", actions.beginRequest());
    } else {
      const stale = view();
      stale.instances[0]!.stale = true;
      applyView(stale);
    }
    await act(async () => render());
    await act(async () => render());
    expect(
      invokeSpy.mock.calls.filter(([command]) => command === "declarative_plugins_build_refresh"),
    ).toHaveLength(1);
    expect(useBuildSystemsStore.getState().status).toBe("ready");
  });
}

test("singleSelect submits a complete declared choice instead of intermediate text", async () => {
  const { host, invokeSpy } = await mount(
    view([
      {
        id: "profile",
        displayName: "Profile",
        kind: "singleSelect",
        value: "debug",
        choices: [
          { value: "debug", title: "Debug" },
          { value: "release", title: "Release" },
        ],
        allowCustom: false,
      },
    ]),
  );
  expect(host.querySelector('input[aria-label="Profile"]')).toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Profile"]')!.click());
  const release = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((option) =>
    option.textContent?.includes("Release"),
  );
  expect(release).toBeDefined();
  await act(async () => release!.click());
  const edits = invokeSpy.mock.calls.filter(
    ([command]) => command === "declarative_plugins_build_set_option",
  );
  expect(edits).toHaveLength(1);
  expect(edits[0]![1]).toMatchObject({ optionId: "profile", value: "release" });
});

test("allowCustom singleSelect commits a chosen custom value", async () => {
  const { host, invokeSpy } = await mount(
    view([
      {
        id: "profile",
        displayName: "Profile",
        kind: "singleSelect",
        value: "debug",
        choices: [{ value: "debug", title: "Debug" }],
        allowCustom: true,
      },
    ]),
  );
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Profile"]')!.click());
  const search = document.querySelector<HTMLInputElement>('input[role="combobox"]')!;
  expect(search).not.toBeNull();
  await act(async () => setInput(search, "custom-profile"));
  expect(
    invokeSpy.mock.calls.filter(([command]) => command === "declarative_plugins_build_set_option"),
  ).toHaveLength(0);
  const custom = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((option) =>
    option.textContent?.includes("custom-profile"),
  );
  expect(custom).toBeDefined();
  await act(async () => custom!.click());
  const edits = invokeSpy.mock.calls.filter(
    ([command]) => command === "declarative_plugins_build_set_option",
  );
  expect(edits).toHaveLength(1);
  expect(edits[0]![1]).toMatchObject({ optionId: "profile", value: "custom-profile" });
});

test("a rejected draft can be submitted again without changing the text", async () => {
  const { host, invokeSpy } = await mount(
    view([
      {
        id: "path",
        displayName: "Path",
        kind: "text",
        value: "initial",
        choices: [],
      },
    ]),
  );
  const input = host.querySelector<HTMLInputElement>('input[aria-label="Path"]')!;
  await act(async () => input.focus());
  await act(async () => setInput(input, "retry-value"));
  invokeSpy.mockRejectedValueOnce(new Error("temporary option failure"));
  const submit = () =>
    input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  await act(async () => {
    submit();
  });
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("temporary option failure");
  expect(input.value).toBe("retry-value");
  await act(async () => {
    submit();
  });
  const edits = invokeSpy.mock.calls.filter(
    ([command]) => command === "declarative_plugins_build_set_option",
  );
  expect(edits).toHaveLength(2);
  expect(edits[1]![1]).toMatchObject({ optionId: "path", value: "retry-value" });
});

for (const kind of ["text", "file", "directory"] as const) {
  test(`${kind} edits retain a local draft and submit only on Enter or blur`, async () => {
    const initial = view([
      {
        id: "path",
        displayName: "Path",
        kind,
        value: "initial",
        choices: [],
      },
    ]);
    const { host, invokeSpy } = await mount(initial);
    const input = host.querySelector<HTMLInputElement>('input[aria-label="Path"]')!;
    await act(async () => input.focus());
    await act(async () => setInput(input, "C:/my folder"));
    expect(input.value).toBe("C:/my folder");
    expect(
      invokeSpy.mock.calls.filter(
        ([command]) => command === "declarative_plugins_build_set_option",
      ),
    ).toHaveLength(0);

    // A watcher response with an effective value does not swallow a local
    // edit while this input owns focus.
    const external = view([{ ...initial.instances[0]!.options[0]!, value: "external" }]);
    await act(async () => applyView(external));
    expect(input.value).toBe("C:/my folder");
    await act(async () =>
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await act(async () => input.blur());
    const edits = invokeSpy.mock.calls.filter(
      ([command]) => command === "declarative_plugins_build_set_option",
    );
    expect(edits).toHaveLength(1);
    expect(edits[0]![1]).toMatchObject({ optionId: "path", value: "C:/my folder" });

    await act(async () => input.focus());
    await act(async () => setInput(input, ""));
    await act(async () => input.blur());
    const finalEdits = invokeSpy.mock.calls.filter(
      ([command]) => command === "declarative_plugins_build_set_option",
    );
    expect(finalEdits).toHaveLength(2);
    expect(finalEdits[1]![1]).toMatchObject({ optionId: "path", value: "" });
  });
}
