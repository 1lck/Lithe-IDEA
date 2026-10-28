import { afterAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { NativePanelStateStore } from "./native-panel-state";
import type {
  NativeCallContext,
  NativeNode,
  NativePanelIdentity,
  NativePanelPort,
  NativeUI,
} from "./native-ui.types";
import controlsFixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json";
import treeFixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-panel.plugin.json";
import formFixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-form.plugin.json";
import { deferred, nativeFunctionFixture } from "./native-functions.test-support";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");
const { NativePanel } = await import("./native-panel");
const identity: NativePanelIdentity = {
  pluginId: "fixture.native",
  packageIdentity: "bytes-a",
  hostWindowId: "main",
  workspaceId: "fixture-workspace",
  windowId: "fixture-panel",
  panelId: "panel",
};

async function mount(element: ReactElement) {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  // Happy DOM has no layout engine. Give the real virtualizer a deterministic
  // viewport without replacing its range calculation or rendered row owner.
  const geometry = ["offsetWidth", "offsetHeight"] as const;
  const previousGeometry = geometry.map((key) =>
    Object.getOwnPropertyDescriptor(HTMLElement.prototype, key),
  );
  for (const key of geometry)
    Object.defineProperty(HTMLElement.prototype, key, {
      configurable: true,
      get(this: HTMLElement) {
        return this.matches('[role="tree"], [role="listbox"]')
          ? key === "offsetHeight"
            ? 300
            : 640
          : 0;
      },
    });
  const restoreGeometry = () =>
    geometry.forEach((key, index) => {
      if (previousGeometry[index])
        Object.defineProperty(HTMLElement.prototype, key, previousGeometry[index]!);
      else Reflect.deleteProperty(HTMLElement.prototype, key);
    });
  const host = document.createElement("div");
  document.body.append(host);
  let root: Root | undefined;
  try {
    await act(async () => {
      root = createRoot(host);
      root.render(element);
    });
  } catch (error) {
    await act(async () => root?.unmount());
    host.remove();
    restoreGeometry();
    environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    throw error;
  }
  return {
    host,
    render: async (element: ReactElement) => {
      await act(async () => root!.render(element));
    },
    close: async () => {
      try {
        await act(async () => root?.unmount());
      } finally {
        host.remove();
        restoreGeometry();
        environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
      }
    },
  };
}
function inputValue(input: HTMLInputElement, value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}
const validate: NativePanelPort["validate"] = async (_ui, data) =>
  (data as { nodes: NativeNode[] }).nodes;
function panel(
  ui: NativeUI,
  port: NativePanelPort,
  store = new NativePanelStateStore(),
  owner = identity,
) {
  return (
    <LocaleProvider language="en-US">
      <NativePanel
        identity={owner}
        title="Fixture panel"
        ui={ui}
        port={port}
        store={store}
        onClose={() => {}}
      />
    </LocaleProvider>
  );
}

test("native toolbar renders every approved host icon and retains undeclared action defaults", async () => {
  const expected = {
    "tool-window": "toolWindowComponents@20x20",
    plugin: "plugin",
    database: "dbms@20x20",
    services: "services@20x20",
    terminal: "terminal",
    search: "search",
    refresh: "refresh",
    reset: "reset",
    run: "run",
    debug: "debug",
    settings: "settings",
    add: "add",
    remove: "delete",
    git: "vcs",
    problems: "problems",
  };
  const core = readFileSync(
    new URL("../../../../../../rust/lithe-core/src/plugins/declarative.rs", import.meta.url),
    "utf8",
  );
  const hostIds = [
    ...core.match(/const HOST_IDS:.*?= &\[([\s\S]*?)\];/)![1].matchAll(/"([^"]+)"/g),
  ].map((match) => match[1]);
  expect(Object.keys(expected)).toEqual(hostIds);
  const ui = structuredClone(treeFixture.ui.toolWindows[0].native) as unknown as NativeUI;
  // Inspect's search declaration is the original production regression.
  expect(ui.actions.find((action) => action.title === "Inspect")?.icon?.host).toBe("search");
  ui.actions = hostIds.map((host) => ({
    id: host,
    title: host,
    kind: "invoke",
    function: "inspect",
    requiresSelection: false,
    icon: { host },
  }));
  ui.actions.push(
    { id: "default-refresh", title: "Default refresh", kind: "refresh", requiresSelection: false },
    {
      id: "default-invoke",
      title: "Default invoke",
      kind: "invoke",
      function: "inspect",
      requiresSelection: false,
    },
  );
  ui.toolbar = ui.actions.map((action) => action.id);
  ui.contextMenu = [];
  const mounted = await mount(panel(ui, { validate }));
  try {
    for (const [host, asset] of Object.entries(expected)) {
      const button = mounted.host.querySelector(`button[aria-label="${host}"]`)!;
      const light = button
        .querySelector(".lithe-idea-icon-light")!
        .getAttribute("href")!
        .replace(/\\/g, "/");
      const dark = button
        .querySelector(".lithe-idea-icon-dark")!
        .getAttribute("href")!
        .replace(/\\/g, "/");
      expect(light).toContain(`/${asset}.svg`);
      expect(dark).toContain(`/${asset}_dark.svg`);
      expect(button.querySelectorAll("svg")).toHaveLength(1);
    }
    expect(
      mounted.host
        .querySelector('button[aria-label="Default refresh"] image')!
        .getAttribute("href")!
        .replace(/\\/g, "/"),
    ).toContain("/redo.svg");
    expect(
      mounted.host
        .querySelector('button[aria-label="Default invoke"] image')!
        .getAttribute("href")!
        .replace(/\\/g, "/"),
    ).toContain("/run.svg");
  } finally {
    await mounted.close();
  }
}, 3000);

test("native disabled fields and actions keep their explanations operable", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const mounted = await mount(panel(ui, { validate }));
  try {
    const disabled = [...ui.controls!, ...ui.buttons!].filter(
      (entry) => entry.enabled === false && entry.info,
    );
    expect(disabled.length).toBeGreaterThan(0);
    for (const entry of disabled) {
      const tip = [...mounted.host.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.getAttribute("aria-label") === `Information for ${entry.label}`,
      )!;
      expect(tip).toBeDefined();
      expect(tip.disabled).toBe(false);
      expect(document.getElementById(tip.getAttribute("aria-describedby")!)?.textContent).toBe(
        entry.info!,
      );
      await act(async () => tip.click());
      expect(tip.getAttribute("aria-expanded")).toBe("true");
      expect(document.querySelector('[role="dialog"]')?.textContent).toBe(entry.info!);
      await act(async () => tip.click());
      expect(tip.getAttribute("aria-expanded")).toBe("false");
    }
  } finally {
    await mounted.close();
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  }
}, 3000);

test("native-controls primary and normal actions retain public button variants and the restored draft", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const store = new NativePanelStateStore();
  const binding = nativeFunctionFixture(identity, ui);
  const port = { validate, functions: binding.port };
  const mounted = await mount(panel(ui, port, store));
  const button = (id: string) => {
    const declaration = ui.buttons!.find((entry) => entry.id === id)!;
    return [...mounted.host.querySelectorAll<HTMLButtonElement>('button[data-slot="button"]')].find(
      (element) => element.textContent === declaration.label,
    )!;
  };
  try {
    for (const id of ["primary-content", "primary-fill", "disabled-primary"])
      expect(button(id).getAttribute("data-variant")).toBe("accent");
    for (const id of ["secondary-content", "secondary-fill", "disabled-button"])
      expect(button(id).getAttribute("data-variant")).toBe("default");

    await act(async () => {
      button("disabled-primary").click();
      button("disabled-button").click();
    });
    expect(button("disabled-primary").disabled).toBe(true);
    expect(button("disabled-button").disabled).toBe(true);
    expect(binding.calls.filter((call) => !!call.actionId)).toHaveLength(0);

    const name = ui.controls!.find((control) => control.id === "name")!;
    await act(async () => {
      inputValue(
        mounted.host.querySelector<HTMLInputElement>(`input[aria-label="${name.label}"]`)!,
        "草稿 😀",
      );
    });
    await mounted.render(<div />);
    await mounted.render(panel(ui, port, store));
    for (const id of ["primary-content", "secondary-content"]) {
      expect(button(id).disabled).toBe(false);
      const before = binding.calls.filter((call) => !!call.actionId).length;
      await act(async () => button(id).click());
      const actions = binding.calls.filter((call) => !!call.actionId);
      expect(actions).toHaveLength(before + 1);
      expect(actions[actions.length - 1].actionId).toBe("changed");
      expect(actions[actions.length - 1].context.values).toEqual(
        Object.fromEntries(
          ui.controls!.map((control) => [
            control.id,
            control.id === "name" ? "草稿 😀" : control.value,
          ]),
        ),
      );
    }

    const normal = ui.buttons!.find((entry) => entry.id === "secondary-content")!;
    const tip = mounted.host.querySelector<HTMLButtonElement>(
      `button[aria-label="Information for ${normal.label}"]`,
    )!;
    expect(tip.disabled).toBe(false);
    await act(async () => tip.click());
    expect(document.querySelector('[role="dialog"]')?.textContent).toBe(normal.info!);
    await act(async () => tip.click());
  } finally {
    await mounted.close();
    await binding.close();
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  }
}, 3000);

test("the real native-controls form renders shared controls and IME Enter commits all current fields once", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const invocations: NativeCallContext[] = [];
  const binding = nativeFunctionFixture(identity, ui);
  const prepare = binding.deps.prepare;
  binding.deps.prepare = (...args) => {
    if (args[1]) invocations.push(args[2]);
    return prepare(...args);
  };
  const port: NativePanelPort = {
    validate,
    functions: binding.port,
  };
  const mounted = await mount(panel(ui, port));
  try {
    for (const control of ui.controls!) {
      expect(mounted.host.textContent).toContain(control.label);
    }
    const name = mounted.host.querySelector<HTMLInputElement>(
      `input[aria-label="${ui.controls![0].label}"]`,
    )!;
    const editor = mounted.host.querySelector<HTMLTextAreaElement>(
      `textarea[aria-label="${ui.controls!.find((control) => control.kind === "editor")!.label}"]`,
    )!;
    expect(name.value).toBe("UI Lab");
    expect(editor.value).toContain("Second line 😀");
    const disabled = ui.controls!.find((control) => control.id === "locked-input")!;
    expect(
      mounted.host.querySelector<HTMLInputElement>(`input[aria-label="${disabled.label}"]`)!
        .disabled,
    ).toBe(true);
    // The disabled field's information button remains independently reachable.
    const disabledLabel = [...mounted.host.querySelectorAll("label")].find(
      (label) => label.textContent === disabled.label,
    )!;
    expect(disabledLabel.parentElement!.querySelector<HTMLButtonElement>("button")!.disabled).toBe(
      false,
    );
    await act(async () => {
      inputValue(name, "中文输入 😀");
      name.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true }),
      );
    });
    expect(name.value).toBe("中文输入 😀");
    expect(invocations).toHaveLength(0);
    await act(async () => {
      name.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(invocations).toHaveLength(1);
    expect(invocations[0].values?.name).toBe("中文输入 😀");
    expect(invocations[0].values?.notes).toBe(editor.value);
    expect(invocations[0].values?.[disabled.id]).toBe(disabled.value);
  } finally {
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("the real native tree fixture virtualizes long results and keeps keyboard selection on expanded children", async () => {
  const ui = treeFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const nodes: NativeNode[] = Array.from({ length: 600 }, (_, index) => ({
    id: `node-${index}`,
    label: index === 0 ? "Branch" : `Node ${index}`,
    ...(index === 0 ? { children: [{ id: "child", label: "Child row" }] } : {}),
  }));
  const binding = nativeFunctionFixture(identity, ui);
  binding.setRead(async (context) => ({ context, phase: "succeeded", result: { nodes } }));
  const mounted = await mount(panel(ui, { validate, functions: binding.port }));
  try {
    const tree = mounted.host.querySelector<HTMLDivElement>("[role=tree]")!;
    expect(tree).not.toBeNull();
    const rows = () => mounted.host.querySelectorAll("[role=treeitem]");
    expect(rows().length).toBeGreaterThan(0);
    expect(rows().length).toBeLessThan(nodes.length);
    await act(async () => {
      mounted.host.querySelector<HTMLButtonElement>('button[aria-label="Expand Branch"]')!.click();
    });
    await act(async () => {
      tree.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    });
    expect(
      mounted.host.querySelector('[role=treeitem][aria-selected="true"]')?.textContent,
    ).toContain("Child row");
    await act(async () => {
      tree.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
    });
    expect(
      mounted.host.querySelector('[role=treeitem][aria-selected="true"]')?.textContent,
    ).toContain("Branch");
    await act(async () => {
      mounted.host.querySelector<HTMLButtonElement>('button[aria-label="Inspect"]')!.click();
    });
    expect(binding.calls.find((call) => call.actionId === "inspect")?.context.selectedID).toBe(
      "node-0",
    );
  } finally {
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("the real native-form fixture restores a local draft after hide and reset restores its declared value", async () => {
  const ui = formFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const store = new NativePanelStateStore();
  const binding = nativeFunctionFixture(identity, ui);
  const port = { validate, functions: binding.port };
  const mounted = await mount(panel(ui, port, store));
  const input = () =>
    mounted.host.querySelector<HTMLInputElement>(`input[aria-label="${ui.controls![0].label}"]`)!;
  try {
    await act(async () => {
      inputValue(input(), "保存草稿 😀");
    });
    await mounted.render(<div />);
    await mounted.render(panel(ui, port, store));
    expect(input().value).toBe("保存草稿 😀");
    await act(async () => {
      mounted.host
        .querySelector<HTMLButtonElement>('button[aria-label="Reset native panel state"]')!
        .click();
    });
    expect(input().value).toBe(ui.controls![0].value as string);
    await mounted.render(<div />);
    await mounted.render(panel(ui, port, store));
    expect(input().value).toBe(ui.controls![0].value as string);
  } finally {
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("replacing a mounted package cancels its load and rejects its late rows", async () => {
  const ui = treeFixture.ui.toolWindows[0].native as unknown as NativeUI;
  let resolve!: (data: unknown) => void;
  const pending = new Promise<unknown>((yes) => {
    resolve = yes;
  });
  let cancelled = false;
  const mounted = await mount(
    panel(ui, {
      validate,
      functions: {
        load: async (_context, signal) => {
          signal.addEventListener(
            "abort",
            () => {
              cancelled = true;
            },
            { once: true },
          );
          return pending;
        },
        invoke: async () => {},
      },
    }),
  );
  try {
    const replacement: NativeUI = {
      schemaVersion: 1,
      id: "replacement",
      kind: "list",
      nodes: [{ id: "new", label: "Replacement row" }],
      actions: [],
      toolbar: [],
      contextMenu: [],
    };
    await mounted.render(
      panel(replacement, { validate }, new NativePanelStateStore(), {
        ...identity,
        packageIdentity: "bytes-b",
      }),
    );
    expect(cancelled).toBe(true);
    await act(async () => {
      resolve({ nodes: [{ id: "old", label: "Late old row" }] });
    });
    expect(mounted.host.textContent).toContain("Replacement row");
    expect(mounted.host.textContent).not.toContain("Late old row");
    expect(mounted.host.querySelector("[role=listbox]")).not.toBeNull();
  } finally {
    resolve({ nodes: [] });
    await mounted.close();
  }
}, 3000);

test("public selectors, segmented choices, checkbox, stepper, search and form buttons reach the typed port with all current values", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const binding = nativeFunctionFixture(identity, ui);
  binding.setRead(async (context) => ({
    context,
    phase: "succeeded",
    result:
      context.functionId === ui.source!.function
        ? { nodes: [] }
        : { message: "Stored current values" },
  }));
  const mounted = await mount(panel(ui, { validate, functions: binding.port }));
  const control = (kind: string) =>
    ui.controls!.find((control) => control.kind === kind && control.enabled !== false)!;
  const lastAction = () => binding.calls.filter((call) => !!call.actionId).slice(-1)[0];
  try {
    const search = control("search");
    const input = mounted.host.querySelector<HTMLInputElement>(
      `input[aria-label="${search.label}"]`,
    )!;
    await act(async () => inputValue(input, "query 😀"));
    expect(binding.calls.filter((call) => !!call.actionId)).toHaveLength(0);
    await act(async () => {
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(lastAction().context.values?.[search.id]).toBe("query 😀");

    const checkbox = control("checkbox");
    await act(async () =>
      mounted.host
        .querySelector<HTMLButtonElement>(`[role=checkbox][aria-label="${checkbox.label}"]`)!
        .click(),
    );
    expect(lastAction().context.values?.[checkbox.id]).toBe(!checkbox.value);

    const segmented = control("segmented");
    const choice = segmented.options!.find((option) => option.id !== segmented.value)!;
    const group = mounted.host.querySelector<HTMLElement>(`[aria-label="${segmented.label}"]`)!;
    await act(async () =>
      [...group.querySelectorAll<HTMLButtonElement>("button")]
        .find((button) => button.textContent === choice.label)!
        .click(),
    );
    expect(lastAction().context.values?.[segmented.id]).toBe(choice.id);

    const stepper = control("stepper");
    const number = mounted.host.querySelector<HTMLInputElement>(
      `input[aria-label="${stepper.label}"]`,
    )!;
    await act(async () =>
      number
        .parentElement!.querySelector<HTMLButtonElement>('button[aria-label="Increase value"]')!
        .click(),
    );
    expect(lastAction().context.values?.[stepper.id]).toBe(Number(stepper.value) + stepper.step!);

    const select = control("select");
    const option = select.options!.find((option) => option.id !== select.value)!;
    await act(async () =>
      mounted.host
        .querySelector<HTMLButtonElement>(`[role=combobox][aria-label="${select.label}"]`)!
        .click(),
    );
    await act(async () =>
      [...document.querySelectorAll<HTMLElement>("[role=option]")]
        .find((node) => node.textContent === option.label)!
        .click(),
    );
    expect(lastAction().context.values?.[select.id]).toBe(option.id);

    const button = ui.buttons!.find((button) => button.primary && button.enabled !== false)!;
    await act(async () =>
      [...mounted.host.querySelectorAll<HTMLButtonElement>("button")]
        .find((node) => node.textContent === button.label)!
        .click(),
    );
    expect(lastAction().actionId).toBe(button.action);
    expect(Object.keys(lastAction().context.values!)).toHaveLength(ui.controls!.length);
    expect(mounted.host.textContent).toContain("Stored current values");
    expect(binding.owners.size).toBe(0);
  } finally {
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("native-controls search clears only its draft, submits empty on Enter and restores the empty draft after hide", async () => {
  const ui = structuredClone(controlsFixture.ui.toolWindows[0].native) as unknown as NativeUI;
  const search = ui.controls!.find((control) => control.kind === "search")!;
  // A nonempty declared default distinguishes a restored empty draft from reset.
  search.value = "declared query";
  const store = new NativePanelStateStore();
  const binding = nativeFunctionFixture(identity, ui);
  const port = { validate, functions: binding.port };
  const mounted = await mount(panel(ui, port, store));
  const input = () =>
    mounted.host.querySelector<HTMLInputElement>(`input[aria-label="${search.label}"]`)!;
  const actions = () => binding.calls.filter((call) => !!call.actionId);
  try {
    expect(input().value).toBe("declared query");
    await act(async () => inputValue(input(), "draft 😀"));
    expect(actions()).toHaveLength(0);
    const clear = mounted.host.querySelector<HTMLButtonElement>(
      'button[aria-label="Clear search"]',
    )!;
    await act(async () => clear.click());
    expect(input().value).toBe("");
    expect(document.activeElement).toBe(input());
    expect(mounted.host.querySelector('button[aria-label="Clear search"]')).toBeNull();
    expect(actions()).toHaveLength(0);
    await act(async () =>
      input().dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    expect(actions()).toHaveLength(1);
    expect(actions()[0].actionId).toBe(search.onCommit!);
    expect(actions()[0].context.values?.[search.id]).toBe("");
    await mounted.render(<div />);
    await mounted.render(panel(ui, port, store));
    expect(input().value).toBe("");
    expect(mounted.host.querySelector('button[aria-label="Clear search"]')).toBeNull();
    expect(actions()).toHaveLength(1);
    expect(binding.owners.size).toBe(0);
  } finally {
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("native-controls disabled search cannot clear while its InfoTip remains operable", async () => {
  const ui = structuredClone(controlsFixture.ui.toolWindows[0].native) as unknown as NativeUI;
  const search = ui.controls!.find((control) => control.kind === "search")!;
  search.enabled = false;
  search.value = "locked query";
  const mounted = await mount(panel(ui, { validate }));
  try {
    const input = mounted.host.querySelector<HTMLInputElement>(
      `input[aria-label="${search.label}"]`,
    )!;
    const clear = mounted.host.querySelector<HTMLButtonElement>(
      'button[aria-label="Clear search"]',
    )!;
    expect(input.disabled).toBe(true);
    expect(clear.disabled).toBe(true);
    await act(async () => clear.click());
    expect(input.value).toBe("locked query");
    const tip = [...mounted.host.querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.getAttribute("aria-label") === `Information for ${search.label}`,
    )!;
    expect(tip.disabled).toBe(false);
    await act(async () => tip.click());
    expect(document.querySelector('[role="dialog"]')?.textContent).toBe(search.info!);
    await act(async () => tip.click());
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  } finally {
    await mounted.close();
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  }
}, 3000);

test("a source form without a refresh action retries unavailable registration and cancels pending consent through public controls", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  expect(ui.actions.some((action) => action.kind === "refresh")).toBe(false);
  const binding = nativeFunctionFixture(identity, ui);
  const open = binding.deps.open;
  let attempts = 0;
  binding.deps.open = (...args) => {
    if (++attempts === 1)
      return Promise.reject({ code: "plugin.function.providerUnavailable", message: "missing" });
    return open(...args);
  };
  const entered = deferred<void>();
  const accepted = deferred<boolean>();
  binding.setApproval(async () => {
    entered.resolve();
    return accepted.promise;
  });
  const mounted = await mount(panel(ui, { validate, functions: binding.port }));
  const button = (label: string) =>
    [...mounted.host.querySelectorAll<HTMLButtonElement>("button")].find(
      (node) => node.textContent === label,
    )!;
  try {
    expect(mounted.host.querySelector("[role=alert]")?.textContent).toBe(
      "Plugin functions are currently unavailable for this panel.",
    );
    await act(async () => {
      button("Retry").click();
      await entered.promise;
    });
    expect(attempts).toBe(2);
    expect(button("Cancel")).toBeTruthy();
    await act(async () => button("Cancel").click());
    expect(binding.confirmed).toHaveLength(0);
    expect(mounted.host.querySelector("[role=alert]")?.textContent).toBeTruthy();
    await act(async () => {
      accepted.resolve(true);
      await Promise.all(binding.sessions.map((session) => session.cancel()));
    });
    expect(binding.confirmed).toHaveLength(0);
    binding.setApproval(async () => true);
    await act(async () => button("Retry").click());
    expect(binding.confirmed).toHaveLength(1);
    expect(mounted.host.querySelector("[role=alert]")).toBeNull();
    expect(binding.owners.size).toBe(0);
  } finally {
    entered.resolve();
    accepted.resolve(false);
    await mounted.close();
    await binding.close();
  }
}, 3000);

test("running native progress is visible and cancelling it prevents a late action message", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const binding = nativeFunctionFixture(identity, ui);
  const entered = deferred<void>();
  const resume = deferred<void>();
  binding.setWait(async () => {
    entered.resolve();
    await resume.promise;
  });
  let running = true;
  binding.setRead(async (context) => {
    if (context.functionId === ui.source!.function)
      return { context, phase: "succeeded", result: { nodes: [] } };
    return running
      ? {
          context,
          phase: "running",
          progress: { message: "Working on current form", percentage: 42 },
        }
      : { context, phase: "succeeded", result: { message: "Late old success" } };
  });
  const mounted = await mount(panel(ui, { validate, functions: binding.port }));
  try {
    const primary = ui.buttons!.find((button) => button.primary && button.enabled !== false)!;
    await act(async () => {
      [...mounted.host.querySelectorAll<HTMLButtonElement>("button")]
        .find((button) => button.textContent === primary.label)!
        .click();
      await entered.promise;
    });
    expect(mounted.host.textContent).toContain("Working on current form 42%");
    await act(async () => {
      [...mounted.host.querySelectorAll<HTMLButtonElement>("button")]
        .find((button) => button.textContent === "Cancel")!
        .click();
    });
    await act(async () => {
      running = false;
      resume.resolve();
      await Promise.all(binding.sessions.map((session) => session.cancel()));
    });
    expect(mounted.host.textContent).not.toContain("Working on current form");
    expect(mounted.host.textContent).not.toContain("Late old success");
    expect(binding.owners.size).toBe(0);
  } finally {
    entered.resolve();
    resume.resolve();
    await mounted.close();
    await binding.close();
  }
}, 3000);
