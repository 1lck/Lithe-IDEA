import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { NativePanel } from "./native-panel";
import { NativePanelStateStore } from "./native-panel-state";
import type { NativeCallContext, NativePanelPort, NativeUI } from "./native-ui.types";
import fixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json";

/** Browser-only regression: serve with the product stylesheet and real renderer.
 * The controlled port does not establish package admission or native execution. */
export async function testNativeActionGroupLayout(host: HTMLDivElement) {
  const started = performance.now();
  const ui = fixture.ui.toolWindows[0].native as unknown as NativeUI;
  const calls: NativeCallContext[] = [];
  const port: NativePanelPort = {
    validate: async () => [],
    functions: {
      load: async () => ({ nodes: [] }),
      invoke: async (_action, context) => {
        calls.push(structuredClone(context));
        return { nodes: [] };
      },
    },
  };
  const check = (condition: unknown, message: string) => {
    if (!condition) throw new Error(message);
  };
  // Each observable browser boundary has its own deadline, including font load.
  const until = async (condition: () => boolean, message: string) => {
    const deadline = performance.now() + 3000;
    while (!condition()) {
      if (performance.now() >= deadline) throw new Error(message);
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    }
  };
  const root = createRoot(host);
  const resizeErrors: string[] = [];
  const onError = (event: ErrorEvent) => {
    if (event.message.includes("ResizeObserver")) resizeErrors.push(event.message);
  };
  window.addEventListener("error", onError);
  const snapshots: { name: string; boxes: ReturnType<DOMRect["toJSON"]>[] }[] = [];
  host.style.height = "900px";
  host.style.width = "2400px";
  try {
    root.render(
      <LocaleProvider language="en-US">
        <NativePanel
          identity={{
            pluginId: fixture.id,
            packageIdentity: "browser-fixture",
            hostWindowId: "browser-test",
            workspaceId: "controlled-workspace",
            windowId: fixture.ui.toolWindows[0].id,
            panelId: ui.id,
          }}
          title={fixture.ui.toolWindows[0].title}
          ui={ui}
          port={port}
          store={new NativePanelStateStore()}
          onClose={() => {}}
        />
      </LocaleProvider>,
    );
    const declarations = ui.buttons!;
    const buttons = () =>
      declarations.map(
        (entry) =>
          [...host.querySelectorAll<HTMLButtonElement>('button[data-slot="button"]')].find(
            (element) => element.textContent === entry.label,
          )!,
      );
    await until(() => buttons().every(Boolean), "native form did not become ready");
    await until(() => document.fonts.status === "loaded", "product fonts did not load");
    const actions = buttons();
    const group = actions[0].parentElement!.parentElement!;
    const rows = () => actions.map((button) => button.parentElement!.getBoundingClientRect());
    const horizontal = () => rows().every((box, index, all) => Math.abs(box.y - all[0].y) < 1);
    const vertical = () =>
      rows().every(
        (box, index, all) =>
          Math.abs(box.x - all[0].x) < 1 && (index === 0 || box.y >= all[index - 1].bottom),
      );
    const snapshot = (name: string) => {
      snapshots.push({ name, boxes: rows().map((box) => box.toJSON()) });
      check(
        buttons().every((button, index) => button === actions[index]),
        "action DOM replaced",
      );
      check(
        actions.every((button, index) => button.textContent === declarations[index].label),
        "order changed",
      );
      for (const [index, entry] of declarations.entries()) {
        check(actions[index].disabled === (entry.enabled === false), "disabled state changed");
        check(
          actions[index].dataset.variant === (entry.primary ? "accent" : "default"),
          "button variant changed",
        );
      }
    };
    await until(horizontal, "wide group must be one horizontal row");
    snapshot("wide");
    const widths = rows().map((box) => box.width);
    const gap = Number.parseFloat(getComputedStyle(group).columnGap);
    const total = widths.reduce((sum, width) => sum + width, 0) + gap * (widths.length - 1);
    // A width that fits multiple actions but not the whole group catches flex-wrap.
    const narrow = Math.max(...widths) + gap + Math.min(...widths);
    check(narrow < total, "fixture must exercise partial-row capacity");
    const name = host.querySelector<HTMLInputElement>(
      `input[aria-label="${ui.controls![0].label}"]`,
    )!;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(
      name,
      "草稿 😀",
    );
    name.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText" }));
    await until(() => name.value === "草稿 😀", "draft edit did not settle");
    actions[0].focus();
    const inset = host.getBoundingClientRect().width - group.getBoundingClientRect().width;
    for (const [label, width, expected] of [
      ["narrow", narrow, vertical],
      ["wide-again", total + gap, horizontal],
      ["narrow-again", narrow, vertical],
    ] as const) {
      host.style.width = `${width + inset}px`;
      await until(expected, `${label}: whole action group must switch orientation`);
      snapshot(label);
      check(document.activeElement === actions[0], `${label}: focused action was lost`);
      check(name.value === "草稿 😀", `${label}: local draft was lost`);
      check(
        rows().every((box, index) => Math.abs(box.width - widths[index]) < 1),
        "natural action widths changed",
      );
    }
    for (const button of actions.filter((button) => button.disabled)) button.click();
    check(calls.length === 0, "disabled action invoked port");
    name.focus();
    for (const [label, width, expected] of [
      ["wide-input-focus", total + gap, horizontal],
      ["narrow-input-focus", narrow, vertical],
    ] as const) {
      host.style.width = `${width + inset}px`;
      await until(expected, `${label}: action group did not reflow`);
      snapshot(label);
      check(document.activeElement === name, `${label}: editing focus was lost`);
      check(name.value === "草稿 😀", `${label}: editing draft was lost`);
    }
    const info = host.querySelector<HTMLButtonElement>(
      `button[aria-label="Information for ${declarations[0].label}"]`,
    )!;
    info.click();
    await until(() => info.getAttribute("aria-expanded") === "true", "InfoTip did not open");
    check(
      document.querySelector('[role="dialog"]')?.textContent === declarations[0].info,
      "InfoTip content changed",
    );
    info.click();
    await until(() => !document.querySelector('[role="dialog"]'), "InfoTip did not close");
    actions[0].click();
    await until(() => calls.length === 1 && !actions[0].disabled, "action did not complete");
    check(
      JSON.stringify(calls[0].values) ===
        JSON.stringify(
          Object.fromEntries(
            ui.controls!.map((control) => [
              control.id,
              control.id === "name" ? "草稿 😀" : control.value,
            ]),
          ),
        ),
      "submission did not preserve all field values",
    );
    check(resizeErrors.length === 0, `resize feedback errors: ${resizeErrors.join("; ")}`);
    return {
      snapshots,
      durationMs: performance.now() - started,
      calls,
      narrow,
      total,
      resizeErrors,
    };
  } finally {
    root.unmount();
    window.removeEventListener("error", onError);
    host.remove();
    check(!document.querySelector('[role="dialog"]'), "InfoTip portal leaked");
  }
}
