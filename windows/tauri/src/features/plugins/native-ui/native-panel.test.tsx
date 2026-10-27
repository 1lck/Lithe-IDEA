import { afterAll, expect, test } from "bun:test";
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

test("the real native-controls form renders shared controls and IME Enter commits all current fields once", async () => {
  const ui = controlsFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const invocations: NativeCallContext[] = [];
  const port: NativePanelPort = {
    validate,
    functions: {
      load: async () => ({ nodes: [] }),
      invoke: async (_action, context) => {
        invocations.push(context);
      },
    },
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
  }
}, 3000);

test("the real native tree fixture virtualizes long results and keeps keyboard selection on expanded children", async () => {
  const ui = treeFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const nodes: NativeNode[] = Array.from({ length: 600 }, (_, index) => ({
    id: `node-${index}`,
    label: index === 0 ? "Branch" : `Node ${index}`,
    ...(index === 0 ? { children: [{ id: "child", label: "Child row" }] } : {}),
  }));
  const mounted = await mount(
    panel(ui, { validate, functions: { load: async () => ({ nodes }), invoke: async () => {} } }),
  );
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
  } finally {
    await mounted.close();
  }
}, 3000);

test("the real native-form fixture restores a local draft after hide and reset restores its declared value", async () => {
  const ui = formFixture.ui.toolWindows[0].native as unknown as NativeUI;
  const store = new NativePanelStateStore();
  const mounted = await mount(panel(ui, { validate }, store));
  const input = () =>
    mounted.host.querySelector<HTMLInputElement>(`input[aria-label="${ui.controls![0].label}"]`)!;
  try {
    await act(async () => {
      inputValue(input(), "保存草稿 😀");
    });
    await mounted.render(<div />);
    await mounted.render(panel(ui, { validate }, store));
    expect(input().value).toBe("保存草稿 😀");
    await act(async () => {
      mounted.host
        .querySelector<HTMLButtonElement>('button[aria-label="Reset native panel state"]')!
        .click();
    });
    expect(input().value).toBe(ui.controls![0].value as string);
    await mounted.render(<div />);
    await mounted.render(panel(ui, { validate }, store));
    expect(input().value).toBe(ui.controls![0].value as string);
  } finally {
    await mounted.close();
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
